#!/usr/bin/env python3
"""Small isolated transport integrity tests; never execute viewer code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import reassemble_preview_assets as subject


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.original = b'unchanged preview source'
        self.name = 'assets/office_preview/test.js'
        self.target = self.root / self.name
        self.target.parent.mkdir(parents=True)
        digest = hashlib.sha256(self.original).hexdigest()
        entry = {'path': self.name, 'size': len(self.original), 'sha256': digest, 'parts': []}
        for i, offset in enumerate(range(0, len(self.original), 8)):
            data = self.original[offset:offset + 8]
            name = f'tool/office_preview/transport/test.js.part{i:03}'
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            entry['parts'].append({'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'git_blob': hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()})
        self.data = {'schema': 1, 'chunk_size': 8, 'files': [entry]}
        self.save_manifest()
        self.addCleanup(patch.stopall)
        patch.object(subject, 'CHUNK_SIZE', 8).start()
        patch.object(subject, 'PINNED', {self.name: (len(self.original), digest)}).start()

    def save_manifest(self):
        (self.root / subject.MANIFEST).write_text(json.dumps(self.data))

    def test_reconstructs_exact_bytes(self):
        subject.run(self.root)
        self.assertEqual(self.target.read_bytes(), self.original)
        subject.run(self.root, verify_only=True)

    def test_existing_original_keeps_timestamp(self):
        self.target.write_bytes(self.original)
        before = self.target.stat().st_mtime_ns
        subject.run(self.root)
        self.assertEqual(self.target.stat().st_mtime_ns, before)

    def test_existing_different_file_not_overwritten(self):
        self.target.write_bytes(b'user-owned different bytes')
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)
        self.assertEqual(self.target.read_bytes(), b'user-owned different bytes')

    def test_concurrent_destination_is_never_overwritten(self):
        original_link = subject.os.link
        def insert_destination(source, destination):
            Path(destination).write_bytes(b'concurrent user data')
            original_link(source, destination)
        with patch.object(subject.os, 'link', side_effect=insert_destination):
            with self.assertRaises(FileExistsError):
                subject.run(self.root)
        self.assertEqual(self.target.read_bytes(), b'concurrent user data')
        self.assertFalse(list(self.target.parent.glob('.preview-reassembly-*')))

    def test_corrupt_chunk_fails_without_partial_destination(self):
        (self.root / self.data['files'][0]['parts'][0]['path']).write_bytes(b'corrupt!')
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)
        self.assertFalse(self.target.exists())
        self.assertFalse(list(self.target.parent.glob('.preview-reassembly-*')))

    def test_missing_chunk_fails(self):
        (self.root / self.data['files'][0]['parts'][0]['path']).unlink()
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_reordered_chunks_fail(self):
        self.data['files'][0]['parts'].reverse(); self.save_manifest()
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_git_blob_digest_is_checked(self):
        self.data['files'][0]['parts'][0]['git_blob'] = '0' * 40; self.save_manifest()
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_full_original_hash_is_pinned(self):
        self.data['files'][0]['sha256'] = '0' * 64; self.save_manifest()
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_path_traversal_rejected(self):
        self.data['files'][0]['path'] = '../outside'; self.save_manifest()
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_chunk_path_traversal_rejected(self):
        self.data['files'][0]['parts'][0]['path'] = '../outside'; self.save_manifest()
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_duplicate_json_keys_rejected(self):
        (self.root / subject.MANIFEST).write_text('{"schema":1,"schema":1}')
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)

    def test_verify_only_requires_original(self):
        with self.assertRaises(subject.IntegrityError): subject.run(self.root, verify_only=True)
        self.assertFalse(self.target.exists())

    def test_verify_only_also_checks_chunks(self):
        self.target.write_bytes(self.original)
        (self.root / self.data['files'][0]['parts'][0]['path']).write_bytes(b'corrupt!')
        with self.assertRaises(subject.IntegrityError): subject.run(self.root, verify_only=True)

    def test_symlink_destination_rejected(self):
        outside = self.root / 'outside'
        outside.write_bytes(self.original)
        try:
            self.target.symlink_to(outside)
        except OSError:
            self.skipTest('Symlink creation unavailable without special privileges')
        with self.assertRaises(subject.IntegrityError): subject.run(self.root)
        self.assertEqual(outside.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
