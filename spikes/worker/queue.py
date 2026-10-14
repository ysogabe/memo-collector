"""Isolated durable-job PoC; no product DB or capture attachments are opened."""
import json, math, sqlite3, time, uuid
from dataclasses import dataclass
from contextlib import contextmanager

@dataclass(frozen=True)
class Policy:
    capturing: bool = False
    low_power: bool = False
    battery: bool = False
    high_load: bool = False

class Queue:
    def __init__(self, path, clock=time.time, max_attempts=3):
        self.clock, self.max_attempts = clock, max_attempts
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, version INTEGER NOT NULL, text TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs(record_id TEXT REFERENCES records(id) ON DELETE CASCADE,
          step TEXT, generation TEXT, version INTEGER, priority INTEGER, state TEXT,
          attempts INTEGER DEFAULT 0, ready_at REAL DEFAULT 0, lease_until REAL, token TEXT,
          PRIMARY KEY(record_id,step,generation,version));
        CREATE TABLE IF NOT EXISTS results(record_id TEXT REFERENCES records(id) ON DELETE CASCADE,
          step TEXT, generation TEXT, version INTEGER, payload TEXT,
          PRIMARY KEY(record_id,step,generation));
        ''')
    @contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try: yield
        except BaseException: self.db.rollback(); raise
        else: self.db.commit()
    def close(self): self.db.close()
    def save(self, rid, text, generation, steps=('embedding',), backfill=False):
        # Record and all requested jobs become durable in the SAME transaction, before inference.
        with self.transaction():
            old=self.db.execute('SELECT version FROM records WHERE id=?',(rid,)).fetchone()
            version=(old['version']+1) if old else 1
            self.db.execute('INSERT INTO records VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,text=excluded.text',(rid,version,text))
            self.db.execute("UPDATE jobs SET state='cancelled',token=NULL WHERE record_id=? AND state IN ('pending','running','retry_wait')",(rid,))
            for step in steps: self.enqueue(rid,step,generation,version,10 if backfill else 0)
        return version
    def enqueue(self, rid, step, generation, version, priority=0):
        self.db.execute("INSERT OR IGNORE INTO jobs(record_id,step,generation,version,priority,state) VALUES(?,?,?,?,?,'pending')",(rid,step,generation,version,priority))
    def claim(self, policy=Policy(), lease_seconds=30):
        if policy.capturing: return None
        now=self.clock()
        with self.transaction():
            self.db.execute("UPDATE jobs SET state=CASE WHEN attempts>=? THEN 'failed' ELSE 'pending' END,token=NULL WHERE state='running' AND lease_until<=?",(self.max_attempts,now))
            allow_backfill=not (policy.low_power or policy.battery or policy.high_load)
            row=self.db.execute("SELECT j.*,r.text FROM jobs j JOIN records r ON r.id=j.record_id AND r.version=j.version WHERE j.state IN ('pending','retry_wait') AND j.ready_at<=? AND (? OR j.priority=0) ORDER BY priority,CASE step WHEN 'guard' THEN 0 WHEN 'intent' THEN 1 ELSE 2 END,record_id LIMIT 1",(now,allow_backfill)).fetchone()
            if not row: return None
            job=dict(row); job['token']=uuid.uuid4().hex; job['attempts']+=1
            # Claim only this pending lease. Intended single scheduler; tokens fence obsolete completions.
            changed=self.db.execute("UPDATE jobs SET state='running',attempts=?,token=?,lease_until=? WHERE record_id=? AND step=? AND generation=? AND version=? AND state IN ('pending','retry_wait')",(job['attempts'],job['token'],now+lease_seconds,*self.key(job))).rowcount
            return job if changed else None
    @staticmethod
    def key(job): return (job['record_id'],job['step'],job['generation'],job['version'])
    def complete(self, job, payload, generation):
        if generation != job['generation']: return False
        if job['step']=='embedding':
            if not isinstance(payload,list) or len(payload)!=256 or any(type(x) not in (float,int) or not math.isfinite(x) for x in payload): return False
            if abs(sum(x*x for x in payload)-1)>.01: return False
        with self.transaction():
            row=self.db.execute("SELECT 1 FROM jobs j JOIN records r ON r.id=j.record_id AND r.version=j.version WHERE j.record_id=? AND j.step=? AND j.generation=? AND j.version=? AND j.state='running' AND j.token=? AND j.lease_until>?",(*self.key(job),job['token'],self.clock())).fetchone()
            if not row: return False
            self.db.execute('INSERT INTO results VALUES(?,?,?,?,?) ON CONFLICT(record_id,step,generation) DO UPDATE SET version=excluded.version,payload=excluded.payload',(job['record_id'],job['step'],generation,job['version'],json.dumps(payload)))
            self.db.execute("UPDATE jobs SET state='succeeded',token=NULL WHERE record_id=? AND step=? AND generation=? AND version=?",self.key(job))
            return True
    def fail(self, job):
        state='failed' if job['attempts']>=self.max_attempts else 'retry_wait'
        with self.transaction():
            return self.db.execute("UPDATE jobs SET state=?,ready_at=?,token=NULL WHERE record_id=? AND step=? AND generation=? AND version=? AND state='running' AND token=?",(state,self.clock()+min(60,2**(job['attempts']-1)),*self.key(job),job['token'])).rowcount == 1
    def cancel(self, rid):
        with self.transaction(): self.db.execute("UPDATE jobs SET state='cancelled',token=NULL WHERE record_id=? AND state IN ('pending','running','retry_wait')",(rid,))
    def delete(self, rid):
        with self.transaction(): self.db.execute('DELETE FROM records WHERE id=?',(rid,))
    def search(self, vector, generation):
        rows=self.db.execute("SELECT a.record_id,a.payload FROM results a JOIN records r ON r.id=a.record_id AND r.version=a.version WHERE a.step='embedding' AND a.generation=?",(generation,)).fetchall()
        return sorted([(sum(x*y for x,y in zip(vector,json.loads(r['payload']))),r['record_id']) for r in rows],reverse=True)
