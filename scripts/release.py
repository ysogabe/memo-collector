#!/usr/bin/env python3
"""Build a clean Release app and a drag-to-Applications DMG (macOS only)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def check_payload(app):
    """Reject known private-data/model payloads and links outside the signed app."""
    forbidden_dirs = {'captures', 'models', '.downloads', '.git', '.aws', '.ssh'}
    forbidden_suffixes = {'.sqlite', '.sqlite3', '.db', '.wav', '.heic', '.safetensors',
                          '.mlmodelc', '.mlpackage', '.pem', '.p12', '.key'}
    for path in app.rglob('*'):
        rel = path.relative_to(app)
        name = path.name.lower()
        if (name in forbidden_dirs or path.suffix.lower() in forbidden_suffixes
                or '.sqlite' in name or name.endswith(('.db-wal', '.db-shm'))
                or name == '.env' or name.startswith('.env.')):
            raise RuntimeError(f'Unexpected private data/model in app: {rel}')
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise RuntimeError(f'App symlink escapes bundle: {rel}')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'dev.ysogabe.ContextCapture':
        raise RuntimeError('Unexpected bundle identifier')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.resolve().is_relative_to(app.resolve()) or not executable.is_file():
        raise RuntimeError('Missing app executable')
    run('lipo', '-verify_arch', 'arm64', executable)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    return info


def signing_args(preview, identity=None, adhoc=False):
    """xcodebuild overrides for code signing.

    Preview keeps app/project.yml's Apple Development / Team signing so the designated
    requirement (identifier + Team certificate) matches development builds. Ad-hoc
    signatures are pinned to a cdhash that changes on every build, so macOS TCC no
    longer matches existing microphone/screen/accessibility grants (shown as allowed in
    System Settings but treated as not determined by the app). Ad-hoc is explicit opt-in.
    """
    if preview:
        return ['CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM='] if adhoc else []
    return [f'CODE_SIGN_IDENTITY={identity}', 'OTHER_CODE_SIGN_FLAGS=--timestamp']


def notarize(path, profile):
    result = run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                 '--wait', '--output-format', 'json', stdout=subprocess.PIPE, text=True)
    response = json.loads(result.stdout)
    if response.get('status') != 'Accepted':
        raise RuntimeError(f"Notarization not accepted: {response.get('status')} (id: {response.get('id')})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview', action='store_true',
                        help='Apple Development signed local test DMG; not for public distribution')
    parser.add_argument('--adhoc', action='store_true',
                        help='With --preview, sign ad-hoc (no certificate). Permissions must be re-granted '
                             'after every rebuild')
    parser.add_argument('--identity', default=os.environ.get('CC_RELEASE_IDENTITY'),
                        help='Full Developer ID Application certificate name')
    parser.add_argument('--notary-profile', default=os.environ.get('CC_NOTARY_PROFILE'),
                        help='Existing notarytool Keychain profile (required for public DMG)')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    if not args.preview and (not args.identity or not args.notary_profile):
        parser.error('Public DMG requires --identity and --notary-profile. Use --preview for local QA.')
    if args.preview and (args.identity or args.notary_profile):
        parser.error('--preview cannot be combined with signing/notarization credentials')
    if args.adhoc and not args.preview:
        parser.error('--adhoc is only valid with --preview')
    if not args.preview and not args.identity.startswith('Developer ID Application:'):
        parser.error('--identity must be a Developer ID Application identity')
    for tool in ('xcodegen', 'xcodebuild', 'hdiutil', 'codesign', 'ditto', 'lipo'):
        if not shutil.which(tool):
            parser.error(f'Missing tool: {tool}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Never copy a checkout or a user's Library. Stage only the build product.
    # Use a unique build directory: an old Debug/Release product cannot leak into the DMG.
    with tempfile.TemporaryDirectory(prefix='cc-release-', dir=ROOT / 'DerivedData') as temp:
        work = Path(temp)
        run('xcodegen', 'generate', '--quiet', cwd=ROOT / 'app')
        lock = ROOT / 'app/ContextCapture.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        lock.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'Packages/ContextCaptureKit/Package.resolved', lock)
        signing = signing_args(args.preview, args.identity, args.adhoc)
        run('xcodebuild', '-project', ROOT / 'app/ContextCapture.xcodeproj',
            '-scheme', 'ContextCapture', '-configuration', 'Release',
            '-derivedDataPath', work / 'build', '-destination', 'generic/platform=macOS',
            '-onlyUsePackageVersionsFromResolvedFile',
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
            'ENABLE_HARDENED_RUNTIME=YES', 'ENABLE_DEBUG_DYLIB=NO',
            *signing, 'build')
        staging = work / 'image'
        staging.mkdir()
        app = staging / 'Context Capture.app'
        run('ditto', work / 'build/Build/Products/Release/ContextCapture.app', app)
        info = check_payload(app)
        version = info['CFBundleShortVersionString']
        build = info['CFBundleVersion']
        if not all(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', v) for v in (version, build)):
            raise RuntimeError('Version/build must be numeric dot-separated values')
        label = f'ContextCapture-{version}-{build}-arm64' + ('-PREVIEW' if args.preview else '')
        destination = output / f'{label}.dmg'
        if destination.exists():
            raise RuntimeError(f'Refusing to replace existing artifact: {destination}')
        if not args.preview:
            # Staple the app as well so it retains its ticket when copied from the DMG.
            archive = work / 'app.zip'
            run('ditto', '-c', '-k', '--keepParent', app, archive)
            notarize(archive, args.notary_profile)
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
        (staging / 'Applications').symlink_to('/Applications')
        (staging / 'インストール方法.txt').write_text(
            'Context Capture.app を Applications にドラッグしてください。\n'
            'コピー後にディスクイメージを取り出し、アプリケーションから起動してください。\n'
            '起動中の旧版がある場合は、終了してから置き換えてください。\n'
            '初回起動で権限の案内とモデル取得（通信約8GB、保存約5.3GB、準備時約13GB）が表示されます。\n'
            '個人の記録・モデルはDMGには含まれません。更新時も個人データは保持されます。\n'
            + ('\nPREVIEW: 開発者の手元確認用。署名・公証済み配布版ではありません。\n'
               if args.preview else ''), encoding='utf-8')
        image = work / f'{label}.dmg'
        run('hdiutil', 'create', '-volname', 'Context Capture', '-srcfolder', staging,
            '-format', 'UDZO', image)
        run('hdiutil', 'verify', image)
        if not args.preview:
            run('codesign', '--sign', args.identity, '--timestamp', image)
            notarize(image, args.notary_profile)
            run('xcrun', 'stapler', 'staple', image)
            run('xcrun', 'stapler', 'validate', image)
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature',
                '--verbose=2', image)
        # Inspect the actual read-only volume before publishing even a local artifact.
        mount = work / 'mounted'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, image)
        try:
            check_payload(mount / app.name)
            if os.readlink(mount / 'Applications') != '/Applications':
                raise RuntimeError('Invalid Applications link')
        finally:
            run('hdiutil', 'detach', mount)
        shutil.copyfile(image, destination)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        destination.with_suffix('.dmg.sha256').write_text(f'{digest}  {destination.name}\n')
        print(f'Created: {destination}', flush=True)


if __name__ == '__main__':
    try:
        (ROOT / 'DerivedData').mkdir(exist_ok=True)
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Release failed: {error}', file=sys.stderr)
        sys.exit(1)
