import 'dart:convert';
import 'dart:typed_data';

import 'document_model.dart';
import 'document_package.dart';

/// Read-only structural preflight, not a replacement for an isolated renderer.
/// PDF/DWG/DXF contain format-specific compressed data and drawing programs;
/// their decoding still relies on the bundled engine's limits and host timeout.
/// CFB allocation chains and ZIP inflation are checked before those parsers run.
void validateBinaryPreview({
  required String format,
  required Uint8List bytes,
  int maxBytes = 32 * 1024 * 1024,
}) {
  if (bytes.isEmpty) {
    throw const DocumentParseException(
      'This document is empty.',
      code: 'empty',
    );
  }
  if (maxBytes < 1 || bytes.length > maxBytes) {
    documentTooLarge('file size');
  }
  switch (format.toLowerCase().replaceFirst(RegExp(r'^\.'), '')) {
    case 'doc':
    case 'ppt':
      _CompoundFile(
        bytes,
        maxBytes,
      ).validate(format.replaceFirst('.', '').toLowerCase());
    case 'xls':
      if (bytes.length >= 8 && bytes[0] == 0xd0 && bytes[1] == 0xcf) {
        _CompoundFile(bytes, maxBytes).validate('xls');
      } else {
        _rawBiff(bytes);
      }
    case 'pdf':
      _pdf(bytes);
    case 'dwg':
      if (bytes.length < 128 ||
          !RegExp(
            r'^AC10[0-9]{2}$',
          ).hasMatch(ascii.decode(bytes.sublist(0, 6), allowInvalid: true))) {
        documentCorrupt('unrecognized DWG header');
      }
    case 'dxf':
      _dxf(bytes);
    case 'note':
    case 'goodnotes':
      _noteArchive(bytes, format.replaceFirst('.', '').toLowerCase(), maxBytes);
    default:
      throw const DocumentParseException(
        'This document format is not supported.',
        code: 'unsupported',
      );
  }
}

// BIFF2–4 XLS files can be a direct record stream rather than a CFB container.
void _rawBiff(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  if (bytes.length < 8 ||
      !const {
        0x0009,
        0x0209,
        0x0409,
        0x0809,
      }.contains(view.getUint16(0, Endian.little))) {
    documentCorrupt('unrecognized legacy Excel container');
  }
  var at = 0, records = 0, eof = false;
  while (at < bytes.length) {
    if (at + 4 > bytes.length) {
      documentCorrupt('truncated Excel record header');
    }
    final type = view.getUint16(at, Endian.little),
        length = view.getUint16(at + 2, Endian.little);
    if (++records > 250000) {
      documentTooLarge('Excel record count');
    }
    if (length > 8224 || at + 4 + length > bytes.length) {
      documentCorrupt('Excel record exceeds stored data');
    }
    if (type == 0x002f) {
      throw const DocumentParseException(
        'Password-protected Office documents are not supported.',
        code: 'encrypted',
      );
    }
    if (type == 0x000a) {
      if (length != 0) {
        documentCorrupt('invalid Excel end record');
      }
      eof = true;
    }
    at += 4 + length;
  }
  if (!eof) {
    documentCorrupt('missing Excel end record');
  }
}

void _pdf(Uint8List bytes) {
  // PDF readers permit a small leading transport prefix before the header.
  final head = latin1.decode(bytes.sublist(0, bytes.length.clamp(0, 1032)));
  final match = RegExp(r'%PDF-[12]\.[0-9]').firstMatch(head);
  if (match == null || match.start > 1024) {
    documentCorrupt('unrecognized PDF header');
  }
  // Deliberately do not regex-parse streams or reject JavaScript tokens here:
  // PDF.js is configured without eval and the offline host denies navigation.
}

void _dxf(Uint8List bytes) {
  const binary = 'AutoCAD Binary DXF\r\n\x1a\x00';
  final prefix = latin1.decode(bytes.sublist(0, bytes.length.clamp(0, 65536)));
  if (prefix.startsWith(binary)) {
    if (bytes.length <= binary.length + 2) {
      documentCorrupt('truncated binary DXF');
    }
    return;
  }
  final text = prefix.replaceFirst('\xef\xbb\xbf', '');
  if (text.contains('\x00') ||
      !RegExp(
        r'(?:^|\r?\n)\s*0\s*\r?\n\s*SECTION\s*(?:\r?\n|$)',
        caseSensitive: false,
      ).hasMatch(text)) {
    documentCorrupt('unrecognized DXF header');
  }
  // The CAD worker separately bounds entities, block recursion and vertex counts.
}

void _noteArchive(Uint8List bytes, String format, int maxBytes) {
  final package = DocumentPackage(
    bytes,
    DocumentPreviewLimits(
      maxCompressedBytes: maxBytes,
      maxInflatedBytes: 64 * 1024 * 1024,
      maxEntryBytes: 24 * 1024 * 1024,
      maxEntries: 5000,
    ),
  );
  package.validateForBrowser();
  final paths = package.entryPaths;
  if (format == 'note') {
    final sessions = paths
        .where(
          (path) => path == 'Session.plist' || path.endsWith('/Session.plist'),
        )
        .toList();
    if (sessions.length != 1) {
      throw const DocumentParseException(
        'This is not a recognized Notability NOTE archive. Export PDF from the original app.',
        code: 'unsupported',
      );
    }
    final data = package.bytes(sessions.single)!;
    final header = latin1.decode(data.sublist(0, data.length.clamp(0, 512)));
    if (!header.startsWith('bplist00') && !header.contains('<plist')) {
      documentCorrupt('unrecognized Notability property list');
    }
  } else if (!paths.any(
    (path) => path == 'index.notes.pb' || path.endsWith('/index.notes.pb'),
  )) {
    throw const DocumentParseException(
      'This is not a recognized Goodnotes archive. Export PDF from the original app.',
      code: 'unsupported',
    );
  }
}

const _free = 0xffffffff,
    _end = 0xfffffffe,
    _fat = 0xfffffffd,
    _dif = 0xfffffffc;

/// CFBF/Compound File allocation validation. File-controlled sector counts are
/// never used for an allocation until checked against the actual input length.
class _CompoundFile {
  _CompoundFile(this.bytes, this.maxBytes) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  final int maxBytes;
  late int sectorSize, sectors;
  late Uint32List fat;
  late Uint32List owners;
  int owner = 0;

  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);
  int offset(int sector) {
    if (sector < 0 || sector >= sectors) {
      documentCorrupt('compound-file sector outside input');
    }
    return (sector + 1) * sectorSize;
  }

  void claim(int sector, int id) {
    offset(sector);
    if (owners[sector] != 0) {
      documentCorrupt('overlapping compound-file allocation');
    }
    owners[sector] = id;
  }

  List<int> chain(int start, {int? count}) {
    if (count == 0) {
      if (start != _end && start != _free) {
        documentCorrupt('nonempty zero-length compound stream');
      }
      return const [];
    }
    final result = <int>[], id = ++owner;
    var sector = start;
    while (sector != _end) {
      if (result.length >= sectors ||
          (count != null && result.length >= count)) {
        documentCorrupt('compound-file chain exceeds stream length');
      }
      claim(sector, id);
      result.add(sector);
      sector = fat[sector];
    }
    if (count != null && result.length != count) {
      documentCorrupt('truncated compound-file chain');
    }
    return result;
  }

  Uint8List join(List<int> chain, int length) {
    if (length < 0 || length > maxBytes || length > chain.length * sectorSize) {
      documentTooLarge('compound-file stream allocation');
    }
    final result = Uint8List(length);
    var at = 0;
    for (final sector in chain) {
      final size = (length - at).clamp(0, sectorSize);
      if (size == 0) {
        break;
      }
      result.setRange(at, at + size, bytes, offset(sector));
      at += size;
    }
    return result;
  }

  void validate(String format) {
    const signature = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
    if (bytes.length < 512 ||
        List.generate(8, (i) => bytes[i] == signature[i]).contains(false)) {
      documentCorrupt('unrecognized legacy Office container');
    }
    final version = u16(26), shift = u16(30);
    if (u16(28) != 0xfffe ||
        !((version == 3 && shift == 9) || (version == 4 && shift == 12)) ||
        u16(32) != 6 ||
        u32(56) != 4096) {
      documentCorrupt('unsupported compound-file header');
    }
    sectorSize = 1 << shift;
    if (bytes.length % sectorSize != 0 || bytes.length < sectorSize * 2) {
      documentCorrupt('truncated compound-file sectors');
    }
    sectors = bytes.length ~/ sectorSize - 1;
    owners = Uint32List(sectors);
    final fatCount = u32(44), difCount = u32(72), miniCount = u32(64);
    if (fatCount < 1 ||
        fatCount > sectors ||
        difCount > sectors ||
        miniCount > sectors) {
      documentCorrupt('compound-file allocation count exceeds input');
    }
    final entriesPerSector = sectorSize ~/ 4;
    if (fatCount * entriesPerSector < sectors) {
      documentCorrupt('incomplete compound-file FAT');
    }
    // A valid FAT cannot need more than one sector of entries beyond the file.
    if (fatCount > (sectors + entriesPerSector - 1) ~/ entriesPerSector) {
      documentCorrupt('excessive compound-file FAT allocation');
    }
    final fatSectors = <int>[];
    void addFat(int sector) {
      if (sector == _free) {
        return;
      }
      if (fatSectors.length >= fatCount) {
        documentCorrupt('unexpected FAT sector');
      }
      claim(sector, ++owner);
      fatSectors.add(sector);
    }

    for (var i = 0; i < 109; i++) {
      addFat(u32(76 + i * 4));
    }
    final difSectors = <int>[];
    var dif = u32(68);
    for (var i = 0; i < difCount; i++) {
      claim(dif, ++owner);
      difSectors.add(dif);
      final at = offset(dif);
      for (var j = 0; j < entriesPerSector - 1; j++) {
        addFat(u32(at + j * 4));
      }
      dif = u32(at + sectorSize - 4);
    }
    if ((dif != _end && !(difCount == 0 && dif == _free)) ||
        fatSectors.length != fatCount) {
      documentCorrupt('invalid compound-file DIFAT chain');
    }
    fat = Uint32List(sectors);
    var cursor = 0;
    for (final sector in fatSectors) {
      final at = offset(sector);
      for (var j = 0; j < entriesPerSector && cursor < sectors; j++, cursor++) {
        fat[cursor] = u32(at + j * 4);
      }
    }
    for (final sector in fatSectors) {
      if (fat[sector] != _fat) {
        documentCorrupt('invalid FAT sector marker');
      }
    }
    for (final sector in difSectors) {
      if (fat[sector] != _dif) {
        documentCorrupt('invalid DIFAT sector marker');
      }
    }
    // Check even orphaned chains; parsers may traverse all sectors, not just streams.
    _acyclic(fat, sectors, const {_end, _free, _fat, _dif});
    final directory = chain(u32(48), count: version == 4 ? u32(40) : null);
    if (directory.isEmpty) {
      documentCorrupt('missing compound-file directory');
    }
    final dirBytes = join(directory, directory.length * sectorSize);
    final dir = ByteData.sublistView(dirBytes), count = dirBytes.length ~/ 128;
    if (count > 65536) {
      documentTooLarge('compound-file directory entries');
    }
    final types = Uint8List(count),
        sizes = List<int>.filled(count, 0),
        starts = Uint32List(count);
    final edges = List<List<int>>.generate(count, (_) => []);
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      final at = i * 128, type = dirBytes[at + 66];
      types[i] = type;
      if (type == 0) {
        continue;
      }
      if (!(type == 1 || type == 2 || type == 5) || (type == 5) != (i == 0)) {
        documentCorrupt('invalid compound-file directory type');
      }
      final nameBytes = dir.getUint16(at + 64, Endian.little);
      if (nameBytes < 2 ||
          nameBytes > 64 ||
          nameBytes.isOdd ||
          dir.getUint16(at + nameBytes - 2, Endian.little) != 0) {
        documentCorrupt('invalid compound-file stream name');
      }
      final name = String.fromCharCodes(
        List.generate(
          nameBytes ~/ 2 - 1,
          (j) => dir.getUint16(at + j * 2, Endian.little),
        ),
      );
      if (type == 2) {
        names.add(name);
      }
      for (final delta in [68, 72, 76]) {
        final next = dir.getUint32(at + delta, Endian.little);
        if (next == _free) {
          continue;
        }
        if (next >= count || (delta == 76 && type == 2)) {
          documentCorrupt('invalid compound-file directory link');
        }
        edges[i].add(next);
      }
      final low = dir.getUint32(at + 120, Endian.little),
          high = dir.getUint32(at + 124, Endian.little);
      if (high != 0 || low > maxBytes || low > bytes.length) {
        documentTooLarge('compound-file stream size');
      }
      sizes[i] = low;
      starts[i] = dir.getUint32(at + 116, Endian.little);
    }
    if (types[0] != 5) {
      documentCorrupt('missing compound-file root');
    }
    _directoryTree(types, edges);
    if (names.contains('EncryptedPackage') ||
        names.contains('EncryptionInfo')) {
      throw const DocumentParseException(
        'Password-protected Office documents are not supported.',
        code: 'encrypted',
      );
    }
    final expected = switch (format) {
      'doc' => names.contains('WordDocument'),
      'xls' => names.contains('Workbook') || names.contains('Book'),
      'ppt' => names.contains('PowerPoint Document'),
      _ => false,
    };
    if (!expected) {
      documentCorrupt('legacy Office format does not match the file extension');
    }
    final rootSectors = chain(
      starts[0],
      count: (sizes[0] + sectorSize - 1) ~/ sectorSize,
    );
    final miniSectors = chain(u32(60), count: miniCount);
    final miniBytes = join(miniSectors, miniSectors.length * sectorSize);
    final miniData = ByteData.sublistView(miniBytes),
        miniCapacity = (sizes[0] + 63) ~/ 64;
    if (miniCapacity > miniBytes.length ~/ 4 && miniCapacity != 0) {
      documentCorrupt('incomplete compound-file mini FAT');
    }
    final miniFat = Uint32List(miniCapacity);
    for (var i = 0; i < miniCapacity; i++) {
      miniFat[i] = miniData.getUint32(i * 4, Endian.little);
    }
    _acyclic(miniFat, miniCapacity, const {_end, _free});
    final miniOwners = Uint8List(miniCapacity);
    for (var i = 1; i < count; i++) {
      if (types[i] != 2) {
        continue;
      }
      final size = sizes[i];
      if (size >= 4096 || size == 0) {
        chain(starts[i], count: (size + sectorSize - 1) ~/ sectorSize);
        continue;
      }
      var sector = starts[i];
      final required = (size + 63) ~/ 64;
      for (var j = 0; j < required; j++) {
        if (sector >= miniCapacity || miniOwners[sector] != 0) {
          documentCorrupt('invalid or overlapping mini-stream allocation');
        }
        miniOwners[sector] = 1;
        sector = miniFat[sector];
      }
      if (sector != _end) {
        documentCorrupt('mini-stream chain exceeds stored size');
      }
    }
    // Root storage allocation was checked even if no visible stream uses it.
    if (rootSectors.length * sectorSize < sizes[0]) {
      documentCorrupt('truncated root mini-stream');
    }
  }
}

void _acyclic(Uint32List links, int count, Set<int> terminals) {
  final states = Uint8List(count);
  for (var start = 0; start < count; start++) {
    if (states[start] != 0) {
      continue;
    }
    var at = start;
    final path = <int>[];
    while (true) {
      if (terminals.contains(at)) {
        break;
      }
      if (at >= count) {
        documentCorrupt('compound-file allocation pointer outside input');
      }
      if (states[at] == 1) {
        documentCorrupt('cyclic compound-file allocation');
      }
      if (states[at] == 2) {
        break;
      }
      states[at] = 1;
      path.add(at);
      at = links[at];
    }
    for (final item in path) {
      states[item] = 2;
    }
  }
}

void _directoryTree(Uint8List types, List<List<int>> edges) {
  final incoming = Uint8List(types.length), state = Uint8List(types.length);
  for (var i = 0; i < types.length; i++) {
    if (types[i] == 0) {
      continue;
    }
    for (final to in edges[i]) {
      if (types[to] == 0 || to == 0 || incoming[to] != 0) {
        documentCorrupt('invalid compound-file directory tree');
      }
      incoming[to] = 1;
    }
  }
  for (var start = 0; start < types.length; start++) {
    if (types[start] == 0 || state[start] != 0) {
      continue;
    }
    final stack = <(int, bool)>[(start, false)];
    while (stack.isNotEmpty) {
      final (at, leaving) = stack.removeLast();
      if (leaving) {
        state[at] = 2;
        continue;
      }
      if (state[at] == 1) {
        documentCorrupt('cyclic compound-file directory');
      }
      if (state[at] == 2) {
        continue;
      }
      state[at] = 1;
      stack.add((at, true));
      for (final next in edges[at]) {
        stack.add((next, false));
      }
    }
  }
}
