"""Read-only bundle/installer checks. Never execute the inspected binaries."""

import argparse
import hashlib
import json
from pathlib import Path
import struct


def pe_machine(path):
    with path.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError(f'Not a PE file: {path.name}')
        stream.seek(0x3c)
        offset_bytes = stream.read(4)
        if len(offset_bytes) != 4:
            raise ValueError(f'Truncated DOS header: {path.name}')
        offset = struct.unpack('<I', offset_bytes)[0]
        if offset < 64 or offset + 6 > path.stat().st_size:
            raise ValueError(f'Invalid PE offset: {path.name}')
        stream.seek(offset)
        if stream.read(4) != b'PE\0\0':
            raise ValueError(f'Invalid PE signature: {path.name}')
        return struct.unpack('<H', stream.read(2))[0]


def file_record(path, root):
    if not path.is_file() or path.stat().st_size == 0 or path.is_symlink():
        raise ValueError(f'Missing, empty or linked file: {path}')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return dict(path=path.relative_to(root).as_posix(), size=path.stat().st_size,
                sha256=digest.hexdigest())


def check(root, commit):
    if len(commit) != 40 or any(c not in '0123456789abcdef' for c in commit):
        raise ValueError('An exact lowercase source SHA is required')
    bundle = root / 'build/windows/x64/runner/Release'
    binaries = ['baocode.exe', 'flutter_windows.dll', 'baocode-browser-host.exe',
                'BaocodeCodexLauncher.exe', 'baocode_wer.dll', 'bao_iroh.dll',
                'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
                'openssh/ssh.exe', 'openssh/ssh-keygen.exe', 'openssh/libcrypto.dll']
    required = binaries + ['data/app.so', 'data/icudtl.dat', 'dev.baocode.browser.json',
                           'remote/VERSION', 'remote/servers.json',
                           'openssh/LICENSE.txt', 'openssh/NOTICE.txt']
    records = [file_record(bundle / name, root) for name in required]
    for name in binaries:
        if pe_machine(bundle / name) != 0x8664:
            raise ValueError(f'Bundle binary is not AMD64: {name}')
    assets = bundle / 'data/flutter_assets'
    if not assets.is_dir() or not any(p.is_file() for p in assets.rglob('*')):
        raise ValueError('Flutter assets are absent or empty')
    host = json.loads((bundle / 'dev.baocode.browser.json').read_text(encoding='utf-8-sig'))
    if host.get('name') != 'dev.baocode.browser' or host.get('type') != 'stdio':
        raise ValueError('Unexpected native-host manifest identity')
    if Path(host.get('path', '')).name != 'baocode-browser-host.exe':
        raise ValueError('Unexpected native-host executable')
    if host.get('allowed_origins') != ['chrome-extension://jfjagocghaaheooicmdnhcholmgdkngk/']:
        raise ValueError('Unexpected native-host allowed origins')
    remote = (bundle / 'remote/VERSION').read_text().strip()
    if remote != '1.7.3.23-958eff42c6ca':
        raise ValueError('Pinned remote-server version changed')
    json.loads((bundle / 'remote/servers.json').read_text())
    versions = [line.split(':', 1)[1].strip() for line in
                (root / 'pubspec.yaml').read_text().splitlines() if line.startswith('version:')]
    if len(versions) != 1 or versions[0] != '1.8.0+28':
        raise ValueError('Unexpected candidate version')
    installers = list((root / 'build/installers').glob('*-setup.exe'))
    if len(installers) != 1 or installers[0].name != 'BaoCode-1.8.0-setup.exe':
        raise ValueError('Expected exactly one candidate installer')
    # Inno's bootstrap may be x86 even when the payload is entirely x64.
    if pe_machine(installers[0]) not in (0x14c, 0x8664):
        raise ValueError('Unsupported installer PE architecture')
    records.append(file_record(installers[0], root))
    return dict(source_commit=commit, version=versions[0], files=records,
                scope='Static build evidence only. No packaged binary executed; no installation, '
                      'upgrade, browser interaction or update signing verified.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = check(args.root.resolve(), args.commit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(report['scope'])


if __name__ == '__main__':
    main()
