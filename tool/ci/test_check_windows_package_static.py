"""Synthetic files only: no Windows executable is launched."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('static_check', Path(__file__).with_name('check_windows_package_static.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class StaticChecks(unittest.TestCase):
    def test_complete_synthetic_bundle_and_rejections(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            bundle = root / 'build/windows/x64/runner/Release'
            binaries = ['baocode.exe', 'flutter_windows.dll', 'baocode-browser-host.exe',
                        'BaocodeCodexLauncher.exe', 'baocode_wer.dll', 'bao_iroh.dll',
                        'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
                        'openssh/ssh.exe', 'openssh/ssh-keygen.exe', 'openssh/libcrypto.dll']
            contents = bytearray(70)
            contents[:2] = b'MZ'
            struct.pack_into('<I', contents, 60, 64)
            contents[64:68] = b'PE\0\0'
            struct.pack_into('<H', contents, 68, 0x8664)
            for name in binaries:
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            for name in ['data/app.so', 'data/icudtl.dat', 'data/flutter_assets/fake',
                         'openssh/LICENSE.txt', 'openssh/NOTICE.txt']:
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fake')
            host = dict(name='dev.baocode.browser', type='stdio', path='baocode-browser-host.exe',
                        allowed_origins=['chrome-extension://jfjagocghaaheooicmdnhcholmgdkngk/'])
            manifest = bundle / 'dev.baocode.browser.json'
            manifest.write_text(json.dumps(host))
            (bundle / 'remote').mkdir()
            (bundle / 'remote/VERSION').write_text('1.7.3.23-958eff42c6ca')
            (bundle / 'remote/servers.json').write_text('{}')
            (root / 'pubspec.yaml').write_text('version: 1.8.0+28\n')
            setup = root / 'build/installers/BaoCode-1.8.0-setup.exe'
            setup.parent.mkdir()
            setup.write_bytes(contents)
            self.assertEqual(checker.check(root, 'a' * 40)['version'], '1.8.0+28')
            app = bundle / 'baocode.exe'
            app.unlink()
            with self.assertRaises(ValueError):
                checker.check(root, 'a' * 40)
            wrong = bytearray(contents)
            struct.pack_into('<H', wrong, 68, 0x14c)
            app.write_bytes(wrong)
            with self.assertRaises(ValueError):
                checker.check(root, 'a' * 40)
            app.write_bytes(contents)
            (root / 'pubspec.yaml').write_text('version: 1.8.0+29\n')
            with self.assertRaises(ValueError):
                checker.check(root, 'a' * 40)
            (root / 'pubspec.yaml').write_text('version: 1.8.0+28\n')
            host['allowed_origins'] = ['chrome-extension://unexpected/']
            manifest.write_text(json.dumps(host))
            with self.assertRaises(ValueError):
                checker.check(root, 'a' * 40)

    def test_pe_architecture_is_read_without_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'fake.exe'
            contents = bytearray(70)
            contents[:2] = b'MZ'
            struct.pack_into('<I', contents, 60, 64)
            contents[64:68] = b'PE\0\0'
            struct.pack_into('<H', contents, 68, 0x8664)
            path.write_bytes(contents)
            self.assertEqual(checker.pe_machine(path), 0x8664)
            contents[64:68] = b'BAD!'
            path.write_bytes(contents)
            with self.assertRaises(ValueError):
                checker.pe_machine(path)

    def test_truncated_and_out_of_range_pe_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'fake.exe'
            for contents in (b'', b'MZ', b'MZ' + bytes(58) + b'\xff\xff\xff\xff'):
                path.write_bytes(contents)
                with self.assertRaises(ValueError):
                    checker.pe_machine(path)

    def test_record_requires_nonempty_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / 'data.bin'
            path.write_bytes(b'abc')
            record = checker.file_record(path, root)
            self.assertEqual(record['size'], 3)
            self.assertEqual(record['sha256'], 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
            path.write_bytes(b'')
            with self.assertRaises(ValueError):
                checker.file_record(path, root)


if __name__ == '__main__':
    unittest.main()
