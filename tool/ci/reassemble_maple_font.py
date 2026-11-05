#!/usr/bin/env python3
"""Reassemble the unchanged OFL font from local, ordered transport chunks.

No downloads, subprocesses, font parsing, installation, or configurable paths.
The command always works relative to this script's repository, not the cwd.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


FONT_PATH = Path("assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf")
CHUNKS_PATH = Path("assets/fonts/maple/chunks")
FONT_SIZE = 20_563_672
FONT_SHA256 = "9ae0c348a44a681fa8fa20a34e782e95316cec880102295a128b65760944c0f5"
CHUNK_SIZE = 4 * 1024 * 1024
PART_COUNT = 5


class FontIntegrityError(ValueError):
    """An input is not the exact expected font transport representation."""


def _plain_path(root, relative, *, required=True, directory=False):
    """Reject symlink/junction paths before reading or replacing local files."""
    cursor = root
    for component in relative.parts:
        cursor = cursor / component
        try:
            metadata = cursor.lstat()
        except FileNotFoundError:
            metadata = None
        # st_file_attributes also catches Windows junctions on Python versions
        # predating Path.is_junction(). No privilege or ACL changes are needed.
        if metadata is not None and (
            stat.S_ISLNK(metadata.st_mode)
            or getattr(metadata, "st_file_attributes", 0) & 0x400
        ):
            raise FontIntegrityError("Linked font paths are not supported")
        if cursor.exists() and cursor != root / relative and not cursor.is_dir():
            raise FontIntegrityError("A font parent path is not a directory")
    path = root / relative
    if not path.exists():
        if required:
            raise FontIntegrityError("A required font input is missing")
        return path
    mode = path.stat().st_mode
    expected = stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)
    if not expected:
        raise FontIntegrityError("Font inputs must be ordinary files/directories")
    return path


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise FontIntegrityError("Duplicate manifest keys are not accepted")
        result[key] = value
    return result


def _manifest(root):
    directory = _plain_path(root, CHUNKS_PATH, directory=True)
    source = _plain_path(root, CHUNKS_PATH / "chunks.json")
    if source.stat().st_size > 16 * 1024:
        raise FontIntegrityError("Font manifest is too large")
    try:
        data = json.loads(source.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FontIntegrityError("Invalid font manifest encoding or JSON") from error
    if not isinstance(data, dict) or set(data) != {"size", "sha256", "parts"}:
        raise FontIntegrityError("Unexpected font manifest schema")
    if type(data["size"]) is not int or data["size"] != FONT_SIZE:
        raise FontIntegrityError("Manifest font size does not match the pinned font")
    if data["sha256"] != FONT_SHA256:
        raise FontIntegrityError("Manifest hash does not match the pinned font")
    parts = data["parts"]
    if not isinstance(parts, list) or len(parts) != PART_COUNT:
        raise FontIntegrityError("The font requires exactly five ordered chunks")
    names = {f"font.part{index:03d}" for index in range(PART_COUNT)}
    if {path.name for path in directory.glob("font.part*")} != names:
        raise FontIntegrityError("Missing or unexpected font chunks")
    for index, part in enumerate(parts):
        if not isinstance(part, dict) or set(part) != {"name", "size", "sha256", "git_blob"}:
            raise FontIntegrityError("Unexpected chunk manifest schema")
        if part["name"] != f"font.part{index:03d}":
            raise FontIntegrityError("Font chunks are not in the fixed sequence")
        size = min(CHUNK_SIZE, FONT_SIZE - index * CHUNK_SIZE)
        if type(part["size"]) is not int or part["size"] != size:
            raise FontIntegrityError("Unexpected chunk size")
        for key, length in (("sha256", 64), ("git_blob", 40)):
            if not isinstance(part[key], str) or not re.fullmatch(rf"[0-9a-f]{{{length}}}", part[key]):
                raise FontIntegrityError("Invalid chunk digest")
    return parts


def _read_part(root, part):
    path = _plain_path(root, CHUNKS_PATH / part["name"])
    if path.stat().st_size != part["size"]:
        raise FontIntegrityError("Font chunk size mismatch")
    with path.open("rb") as stream:
        data = stream.read(part["size"] + 1)
    if len(data) != part["size"] or hashlib.sha256(data).hexdigest() != part["sha256"]:
        raise FontIntegrityError("Font chunk digest mismatch")
    git_blob = hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()
    if git_blob != part["git_blob"]:
        raise FontIntegrityError("Font chunk Git object digest mismatch")
    return data


def verify_font(root):
    path = _plain_path(Path(root).resolve(), FONT_PATH)
    if path.stat().st_size != FONT_SIZE:
        raise FontIntegrityError("Reassembled font size mismatch")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(data)
    if digest.hexdigest() != FONT_SHA256:
        raise FontIntegrityError("Reassembled font digest mismatch")
    return path


def reassemble(root):
    """The root argument exists for isolated tests; the CLI has no path options."""
    root = Path(root).resolve()
    parts = _manifest(root)
    target = _plain_path(root, FONT_PATH, required=False)
    # Do not silently replace an existing different file.
    exists = target.exists()
    if exists:
        verify_font(root)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=target.parent, prefix=".maple-reassembly-", delete=False
        ) as output:
            temporary = Path(output.name)
            digest = hashlib.sha256()
            size = 0
            for part in parts:
                data = _read_part(root, part)
                output.write(data)
                digest.update(data)
                size += len(data)
            if size != FONT_SIZE or digest.hexdigest() != FONT_SHA256:
                raise FontIntegrityError("Assembled bytes do not match the pinned original font")
            output.flush()
            os.fsync(output.fileno())
        if exists:
            # Both the parts and the existing file are verified; leave its bytes
            # and timestamps untouched rather than unnecessarily replacing it.
            verify_font(root)
        else:
            _plain_path(root, FONT_PATH, required=False)
            if target.exists():
                raise FontIntegrityError("Font destination appeared during reconstruction")
            os.replace(temporary, target)
            temporary = None
        return verify_font(root)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    if sys.argv[1:] not in ([], ["--verify-only"]):
        raise SystemExit("Usage: reassemble_maple_font.py [--verify-only]")
    root = Path(__file__).resolve().parents[2]
    try:
        path = verify_font(root) if sys.argv[1:] else reassemble(root)
    except (OSError, FontIntegrityError) as error:
        raise SystemExit(f"Font integrity validation failed: {type(error).__name__}: {error}") from error
    print(f"Verified {path.relative_to(root).as_posix()}: {FONT_SIZE} bytes, SHA-256 {FONT_SHA256}")


if __name__ == "__main__":
    main()
