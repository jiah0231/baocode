#!/usr/bin/env python3
"""Reconstruct byte-identical preview bundles/source archives from local chunks.

No network, subprocesses, extraction, installation, or configurable CLI paths.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

CHUNK_SIZE = 4 * 1024 * 1024
MANIFEST = Path('tool/office_preview/transport/manifest.json')
PINNED = {'assets/office_preview/cad.js': (14035150,
                                  '19bdd7fca435145b7b4fe70561713a19c93fddea96d9ffda553ab795a35e4956'),
 'assets/office_preview/goodnotes.js': (4565840,
                                        '1e7d267d1dd49b181e72927f9ff0b5a28010da43482c344bdae82748eb555ad8'),
 'assets/office_preview/notability.js': (4563930,
                                         '867beae37e7b6d0242bb4b89c3bdad6fdd5effe3e029f509daac0bc04b25cd2c'),
 'assets/office_preview/pdf.js': (4449241,
                                  '8cadd72b03c3de83cc36e0bbb21c927c24efe24a558d774f80dc5a7cfb3827e5'),
 'tool/office_preview/corresponding_source/dwf-viewer-0.6.7.tar.gz': (17715681,
                                                                      'f41e736455f7f52292c979831cbd1d957e854d64952cd82dc8e5b3073464c758'),
 'tool/office_preview/corresponding_source/libredwg-web-0.7.9.tar.gz': (23621657,
                                                                        'af350d628535a2842262af5b49d50568b6dae62854667e13bb9f161b26c00431')}


class IntegrityError(ValueError):
    pass


def plain_path(root, relative, required=True):
    if relative.is_absolute() or '..' in relative.parts:
        raise IntegrityError('Only fixed repository-relative paths are accepted')
    cursor = root
    for component in relative.parts:
        cursor /= component
        try:
            metadata = cursor.lstat()
        except FileNotFoundError:
            metadata = None
        if metadata and (stat.S_ISLNK(metadata.st_mode) or getattr(metadata, 'st_file_attributes', 0) & 0x400):
            raise IntegrityError('Linked asset paths are not accepted')
        if metadata and cursor != root / relative and not stat.S_ISDIR(metadata.st_mode):
            raise IntegrityError('Asset parent is not a directory')
    target = root / relative
    if target.exists() and not target.is_file():
        raise IntegrityError('Asset must be an ordinary file')
    if required and not target.exists():
        raise IntegrityError('Required asset is missing')
    return target


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise IntegrityError('Duplicate manifest key')
        result[key] = value
    return result


def manifest(root):
    path = plain_path(root, MANIFEST)
    if path.stat().st_size > 64 * 1024:
        raise IntegrityError('Manifest is too large')
    data = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_object)
    if not isinstance(data, dict) or set(data) != {'schema', 'chunk_size', 'files'} or data['schema'] != 1 or data['chunk_size'] != CHUNK_SIZE:
        raise IntegrityError('Unexpected manifest schema')
    files = data['files']
    if not isinstance(files, list) or len(files) != len(PINNED):
        raise IntegrityError('Unexpected file count')
    seen = set()
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {'path', 'size', 'sha256', 'parts'}:
            raise IntegrityError('Unexpected file schema')
        name = entry['path']
        if not isinstance(name, str) or name not in PINNED or name in seen:
            raise IntegrityError('Unexpected or repeated file path')
        seen.add(name)
        size, digest = PINNED[name]
        if type(entry['size']) is not int or entry['size'] != size or entry['sha256'] != digest:
            raise IntegrityError('Original size or hash differs from reviewed source')
        parts = entry['parts']
        count = (size + CHUNK_SIZE - 1) // CHUNK_SIZE
        if not isinstance(parts, list) or len(parts) != count:
            raise IntegrityError('Unexpected chunk count')
        for i, part in enumerate(parts):
            expected_path = f'tool/office_preview/transport/{Path(name).name}.part{i:03}'
            if not isinstance(part, dict) or set(part) != {'path', 'size', 'sha256', 'git_blob'}:
                raise IntegrityError('Unexpected chunk schema')
            if part['path'] != expected_path or type(part['size']) is not int or part['size'] != min(CHUNK_SIZE, size - i * CHUNK_SIZE):
                raise IntegrityError('Unexpected chunk order, path or size')
            for key, length in [('sha256', 64), ('git_blob', 40)]:
                if not isinstance(part[key], str) or not re.fullmatch(rf'[0-9a-f]{{{length}}}', part[key]):
                    raise IntegrityError('Invalid chunk digest')
    return files


def verify_file(root, entry):
    path = plain_path(root, Path(entry['path']))
    if path.stat().st_size != entry['size']:
        raise IntegrityError(f"Original size mismatch: {entry['path']}")
    digest = hashlib.sha256()
    total = 0
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            total += len(data)
            if total > entry['size']:
                raise IntegrityError('Original grew while reading')
            digest.update(data)
    if total != entry['size'] or digest.hexdigest() != entry['sha256']:
        raise IntegrityError(f"Original digest mismatch: {entry['path']}")
    return path


def read_part(root, part):
    path = plain_path(root, Path(part['path']))
    if path.stat().st_size != part['size']:
        raise IntegrityError('Chunk size mismatch')
    with path.open('rb') as stream:
        data = stream.read(part['size'] + 1)
    git_blob = hashlib.sha1(f'blob {len(data)}\0'.encode('ascii') + data).hexdigest()
    if len(data) != part['size'] or hashlib.sha256(data).hexdigest() != part['sha256'] or git_blob != part['git_blob']:
        raise IntegrityError('Chunk digest mismatch')
    return data


def run(root, verify_only=False):
    root = Path(root).resolve()
    for entry in manifest(root):
        target = plain_path(root, Path(entry['path']), required=verify_only)
        exists = target.exists()
        if exists:
            verify_file(root, entry)
        temporary = None
        try:
            if not verify_only:
                with tempfile.NamedTemporaryFile(mode='wb', dir=target.parent, prefix='.preview-reassembly-', delete=False) as output:
                    temporary = Path(output.name)
                    digest = hashlib.sha256()
                    size = 0
                    for part in entry['parts']:
                        data = read_part(root, part)
                        output.write(data)
                        digest.update(data)
                        size += len(data)
                    if size != entry['size'] or digest.hexdigest() != entry['sha256']:
                        raise IntegrityError('Reassembled bytes differ from reviewed original')
                    output.flush()
                    os.fsync(output.fileno())
                if not exists:
                    plain_path(root, Path(entry['path']), required=False)
                    if target.exists():
                        raise IntegrityError('Destination appeared during reconstruction')
                    # Same-directory hard-link publication is atomic and fails
                    # if any destination appeared, rather than replacing it.
                    os.link(temporary, target)
                    temporary.unlink()
                    temporary = None
            else:
                # Verify transport chunks too, not just the reconstructed file.
                for part in entry['parts']:
                    read_part(root, part)
            verify_file(root, entry)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def main():
    if sys.argv[1:] not in ([], ['--verify-only']):
        raise SystemExit('Usage: reassemble_preview_assets.py [--verify-only]')
    try:
        run(Path(__file__).resolve().parents[2], verify_only=bool(sys.argv[1:]))
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise SystemExit(f'Preview transport integrity failed: {error}') from error
    print(f'Verified {len(PINNED)} original preview bundles/source archives and all transport chunks.')


if __name__ == '__main__':
    main()
