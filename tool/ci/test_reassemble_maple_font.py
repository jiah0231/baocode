"""Local byte-only tests. No font engine, browser, application, or network."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import reassemble_maple_font as font


class FontReassemblyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="font-byte-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / font.CHUNKS_PATH
        source = Path(__file__).resolve().parents[2] / font.CHUNKS_PATH
        shutil.copytree(source, self.directory)
        self.target = self.root / font.FONT_PATH
        self.manifest_path = self.directory / "chunks.json"
        self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def assert_rejected(self):
        with self.assertRaises(font.FontIntegrityError):
            font.reassemble(self.root)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.glob(".maple-reassembly-*")), [])

    def test_exact_original_bytes_and_idempotent_reassembly(self):
        font.reassemble(self.root)
        self.assertEqual(self.target.stat().st_size, 20_563_672)
        self.assertEqual(
            hashlib.sha256(self.target.read_bytes()).hexdigest(),
            "9ae0c348a44a681fa8fa20a34e782e95316cec880102295a128b65760944c0f5",
        )
        before = self.target.stat().st_mtime_ns
        font.reassemble(self.root)
        self.assertEqual(self.target.stat().st_mtime_ns, before)

    def test_missing_chunk(self):
        (self.directory / "font.part002").unlink()
        self.assert_rejected()

    def test_extra_chunk(self):
        (self.directory / "font.part005").write_bytes(b"extra")
        self.assert_rejected()

    def test_manifest_order_is_not_inferred_from_names(self):
        self.manifest["parts"][0], self.manifest["parts"][1] = (
            self.manifest["parts"][1], self.manifest["parts"][0]
        )
        self.write_manifest()
        self.assert_rejected()

    def test_duplicate_chunk(self):
        self.manifest["parts"][1] = self.manifest["parts"][0]
        self.write_manifest()
        self.assert_rejected()

    def test_traversal_and_absolute_names(self):
        for name in ("../font.part000", "C:/font.part000", "/font.part000"):
            with self.subTest(name=name):
                self.manifest["parts"][0]["name"] = name
                self.write_manifest()
                self.assert_rejected()

    def test_manifest_cannot_select_another_output_or_font(self):
        self.manifest["target"] = "../other.ttf"
        self.write_manifest()
        self.assert_rejected()
        del self.manifest["target"]
        self.manifest["sha256"] = "0" * 64
        self.write_manifest()
        self.assert_rejected()

    def test_chunk_and_total_size_are_fixed(self):
        self.manifest["size"] += 1
        self.write_manifest()
        self.assert_rejected()
        self.manifest["size"] -= 1
        self.manifest["parts"][0]["size"] -= 1
        self.write_manifest()
        self.assert_rejected()

    def test_truncated_chunk(self):
        with (self.directory / "font.part004").open("r+b") as stream:
            stream.truncate(10)
        self.assert_rejected()

    def test_wrong_chunk_digest(self):
        self.manifest["parts"][0]["sha256"] = "0" * 64
        self.write_manifest()
        self.assert_rejected()

    def test_wrong_git_object_digest(self):
        self.manifest["parts"][0]["git_blob"] = "0" * 40
        self.write_manifest()
        self.assert_rejected()

    def test_changed_chunk_with_matching_metadata_still_fails_total_pin(self):
        part = self.manifest["parts"][0]
        path = self.directory / part["name"]
        data = bytearray(path.read_bytes())
        data[100] ^= 1
        path.write_bytes(data)
        part["sha256"] = hashlib.sha256(data).hexdigest()
        part["git_blob"] = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        self.write_manifest()
        self.assert_rejected()

    def test_duplicate_json_keys(self):
        raw = self.manifest_path.read_text(encoding="utf-8")
        self.manifest_path.write_text('{"size":1,' + raw[1:], encoding="utf-8")
        self.assert_rejected()

    def test_existing_different_font_is_not_overwritten(self):
        self.target.write_bytes(b"leave this file alone")
        with self.assertRaises(font.FontIntegrityError):
            font.reassemble(self.root)
        self.assertEqual(self.target.read_bytes(), b"leave this file alone")

    def test_atomic_replace_failure_cleans_temporary_file(self):
        with mock.patch.object(font.os, "replace", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                font.reassemble(self.root)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.glob(".maple-reassembly-*")), [])

    def test_existing_good_font_is_kept_when_a_chunk_is_corrupt(self):
        font.reassemble(self.root)
        before = self.target.read_bytes()
        (self.directory / "font.part003").write_bytes(b"bad")
        with self.assertRaises(font.FontIntegrityError):
            font.reassemble(self.root)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(list(self.target.parent.glob(".maple-reassembly-*")), [])

    @unittest.skipUnless(os.name == "posix", "Symlink creation needs Windows-specific privilege")
    def test_linked_chunk_is_rejected(self):
        path = self.directory / "font.part000"
        real = self.root / "other.bin"
        path.rename(real)
        path.symlink_to(real)
        self.assert_rejected()

    @unittest.skipUnless(os.name == "posix", "Symlink creation needs Windows-specific privilege")
    def test_linked_output_is_rejected_without_touching_destination(self):
        outside = self.root / "other.ttf"
        outside.write_bytes(b"untouched")
        self.target.symlink_to(outside)
        with self.assertRaises(font.FontIntegrityError):
            font.reassemble(self.root)
        self.assertEqual(outside.read_bytes(), b"untouched")

    def test_verify_only_rejects_missing_and_changed_output(self):
        with self.assertRaises(font.FontIntegrityError):
            font.verify_font(self.root)
        font.reassemble(self.root)
        with self.target.open("r+b") as stream:
            stream.seek(200)
            stream.write(b"mutation")
        with self.assertRaises(font.FontIntegrityError):
            font.verify_font(self.root)

    def test_windows_reparse_attribute_is_rejected_without_creating_links(self):
        original = Path.lstat

        def fake_lstat(path):
            result = original(path)
            if path == self.directory:
                return SimpleNamespace(st_mode=result.st_mode, st_file_attributes=0x400)
            return result

        with mock.patch.object(Path, "lstat", fake_lstat):
            self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
