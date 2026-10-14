"""Bounded JSON-lines client. One request in flight, deadline + shape/key fences."""
import json, math, os, selectors, subprocess, tempfile, time
class WorkerError(Exception): pass
class Client:
    def __init__(self, command, key, startup_timeout=120, request_timeout=5, max_restarts=2):
        self.command,self.key=command,key
        self.startup_timeout,self.request_timeout,self.max_restarts=startup_timeout,request_timeout,max_restarts
        self.process=None; self.buffer=b''; self.restarts=0; self.sequence=0; self.ready=None
        self.log=tempfile.TemporaryFile()
    def close(self):
        if self.process:
            self.process.kill() if self.process.poll() is None else None
            self.process.wait(timeout=5)
            self.process.stdin.close(); self.process.stdout.close(); self.process=None
        self.buffer=b''
    def dispose(self): self.close(); self.log.close()
    def _wait(self, fd, event, deadline):
        if time.monotonic()>=deadline: raise WorkerError('timeout')
        with selectors.DefaultSelector() as sel:
            sel.register(fd,event)
            if not sel.select(max(0,deadline-time.monotonic())): raise WorkerError('timeout')
    def _line(self, deadline):
        while b'\n' not in self.buffer:
            self._wait(self.process.stdout,selectors.EVENT_READ,deadline)
            try: data=os.read(self.process.stdout.fileno(),4096)
            except BlockingIOError: continue
            if not data: raise WorkerError('worker_exit')
            self.buffer+=data
            if len(self.buffer)>65536: raise WorkerError('oversize_response')
        line,self.buffer=self.buffer.split(b'\n',1)
        try: return json.loads(line)
        except (ValueError,UnicodeDecodeError): raise WorkerError('invalid_json')
    def start(self):
        start=time.monotonic(); self.close()
        self.process=subprocess.Popen(self.command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log)
        os.set_blocking(self.process.stdout.fileno(),False); os.set_blocking(self.process.stdin.fileno(),False)
        try:
            ready=self._line(time.monotonic()+self.startup_timeout)
            if not isinstance(ready,dict) or ready.get('event')!='ready' or ready.get('key')!=self.key or ready.get('dimension')!=256: raise WorkerError('ready_mismatch')
            self.ready=ready; self.start_milliseconds=(time.monotonic()-start)*1000
        except Exception: self.close(); raise
    def request(self, op, text='', title=None):
        self.sequence+=1; identifier=str(self.sequence)
        body=json.dumps({'id':identifier,'op':op,'text':text,'title':title},ensure_ascii=False).encode()+b'\n'
        if len(body)>16384 or len(text.encode())>8000: raise WorkerError('oversize_request')
        for attempt in range(self.max_restarts+1):
            try:
                if self.process is None: self.start()
                deadline=time.monotonic()+self.request_timeout
                written=0
                while written<len(body):
                    self._wait(self.process.stdin,selectors.EVENT_WRITE,deadline)
                    try: written+=os.write(self.process.stdin.fileno(),body[written:])
                    except BlockingIOError: continue
                reply=self._line(deadline)
                if not isinstance(reply,dict) or reply.get('id')!=identifier or 'error' in reply: raise WorkerError('response_mismatch')
                if op in ('query','document'):
                    v=reply.get('vector')
                    if reply.get('key')!=self.key or not isinstance(v,list) or len(v)!=256 or any(type(x) not in (int,float) or not math.isfinite(x) for x in v) or abs(sum(x*x for x in v)-1)>.01: raise WorkerError('vector_mismatch')
                return reply
            except (WorkerError,OSError,ValueError):
                self.close()
                if attempt==self.max_restarts or self.restarts>=self.max_restarts: raise WorkerError('restart_budget_exhausted')
                self.restarts+=1
        raise WorkerError('unreachable')
