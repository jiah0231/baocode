import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:baocode/ide/document/document_model.dart';
import 'package:baocode/ide/document/preview_binary_guard.dart';
import 'package:flutter_test/flutter_test.dart';

const _free = 0xffffffff, _end = 0xfffffffe;

Uint8List _compound({String stream = 'WordDocument', bool mini = false}) {
  final count = mini ? 4 : 10;
  final bytes = Uint8List((count + 1) * 512);
  final data = ByteData.sublistView(bytes);
  void u16(int at, int value) => data.setUint16(at, value, Endian.little);
  void u32(int at, int value) => data.setUint32(at, value, Endian.little);
  bytes.setAll(0, [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]);
  u16(24, 0x003e);
  u16(26, 3);
  u16(28, 0xfffe);
  u16(30, 9);
  u16(32, 6);
  u32(44, 1);
  u32(48, 1);
  u32(56, 4096);
  u32(60, mini ? 3 : _end);
  u32(64, mini ? 1 : 0);
  u32(68, _end);
  u32(72, 0);
  for (var i = 0; i < 109; i++) {
    u32(76 + i * 4, _free);
  }
  u32(76, 0);
  for (var i = 0; i < 128; i++) {
    u32(512 + i * 4, _free);
  }
  u32(512, 0xfffffffd);
  u32(516, _end);
  if (mini) {
    u32(520, _end);
    u32(524, _end);
  } else {
    for (var i = 2; i < 10; i++) {
      u32(512 + i * 4, i == 9 ? _end : i + 1);
    }
  }
  void entry(
    int index,
    String name,
    int type,
    int start,
    int size, {
    int child = _free,
  }) {
    final at = 1024 + index * 128;
    for (var i = 0; i < name.length; i++) {
      u16(at + i * 2, name.codeUnitAt(i));
    }
    u16(at + 64, (name.length + 1) * 2);
    bytes[at + 66] = type;
    bytes[at + 67] = 1;
    u32(at + 68, _free);
    u32(at + 72, _free);
    u32(at + 76, child);
    u32(at + 116, start);
    u32(at + 120, size);
  }

  entry(0, 'Root Entry', 5, mini ? 2 : _end, mini ? 64 : 0, child: 1);
  entry(1, stream, 2, mini ? 0 : 2, mini ? 8 : 4096);
  if (mini) {
    for (var i = 0; i < 128; i++) {
      u32(2048 + i * 4, _free);
    }
    u32(2048, _end);
  }
  return bytes;
}

Uint8List _change(Uint8List source, int offset, int value) {
  final copy = Uint8List.fromList(source);
  ByteData.sublistView(copy).setUint32(offset, value, Endian.little);
  return copy;
}

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  void validate(
    Uint8List bytes, {
    String format = 'doc',
    int maxBytes = 32 * 1024 * 1024,
  }) => validateBinaryPreview(format: format, bytes: bytes, maxBytes: maxBytes);
  final invalid = throwsA(isA<DocumentParseException>());

  test('accepts structurally bounded standard and mini CFB streams', () {
    validate(_compound());
    validate(_compound(mini: true));
    validate(_compound(stream: 'Workbook'), format: 'xls');
    validate(_compound(stream: 'Book', mini: true), format: '.XLS');
    validate(_compound(stream: 'PowerPoint Document'), format: 'ppt');
  });
  test('rejects empty, oversized and mismatched legacy formats', () {
    expect(() => validate(Uint8List(0)), invalid);
    expect(() => validate(_compound(), maxBytes: 1000), invalid);
    expect(() => validate(_compound(), format: 'xls'), invalid);
    expect(() => validate(Uint8List(1024)), invalid);
  });
  test('rejects FAT counts controlled beyond physical file size', () {
    expect(() => validate(_change(_compound(), 44, 0x7fffffff)), invalid);
    expect(() => validate(_change(_compound(), 64, 0x7fffffff)), invalid);
    expect(() => validate(_change(_compound(), 72, 0x7fffffff)), invalid);
  });
  test(
    'rejects sector cycles, out-of-file pointers and overlapping streams',
    () {
      expect(() => validate(_change(_compound(), 512 + 2 * 4, 2)), invalid);
      expect(() => validate(_change(_compound(), 512 + 2 * 4, 9999)), invalid);
      // Stream begins at the already claimed directory allocation.
      expect(
        () => validate(_change(_compound(), 1024 + 128 + 116, 1)),
        invalid,
      );
    },
  );
  test('rejects forged stream length before allocation', () {
    expect(
      () => validate(_change(_compound(), 1024 + 128 + 120, 0x7fffffff)),
      invalid,
    );
    expect(() => validate(_change(_compound(), 1024 + 128 + 124, 1)), invalid);
    expect(
      () => validate(_change(_compound(), 1024 + 128 + 120, 512)),
      invalid,
    );
  });
  test('rejects directory cycles and invalid directory references', () {
    expect(() => validate(_change(_compound(), 1024 + 128 + 72, 1)), invalid);
    expect(() => validate(_change(_compound(), 1024 + 76, 9999)), invalid);
    expect(() => validate(_change(_compound(), 1024 + 128 + 76, 0)), invalid);
  });
  test('rejects invalid mini-sector chains', () {
    expect(() => validate(_change(_compound(mini: true), 2048, 0)), invalid);
    expect(() => validate(_change(_compound(mini: true), 2048, 2000)), invalid);
    expect(
      () => validate(_change(_compound(mini: true), 1024 + 128 + 116, 2)),
      invalid,
    );
  });
  test('recognizes encrypted OOXML wrapped in a compound file', () {
    expect(
      () => validate(_compound(stream: 'EncryptedPackage')),
      throwsA(
        isA<DocumentParseException>().having(
          (e) => e.code,
          'code',
          'encrypted',
        ),
      ),
    );
  });
  test(
    'supports bounded raw legacy BIFF records and rejects broken lengths',
    () {
      final biff = Uint8List.fromList([9, 0, 4, 0, 0, 0, 0x10, 0, 10, 0, 0, 0]);
      validate(biff, format: 'xls');
      final corrupt = Uint8List.fromList(biff)..[2] = 255;
      expect(() => validate(corrupt, format: 'xls'), invalid);
      final encrypted = Uint8List.fromList([
        9,
        0,
        4,
        0,
        0,
        0,
        0x10,
        0,
        0x2f,
        0,
        0,
        0,
        10,
        0,
        0,
        0,
      ]);
      expect(() => validate(encrypted, format: 'xls'), invalid);
    },
  );
  test(
    'PDF accepts bounded header prefix but is not treated as a full parser',
    () {
      validate(Uint8List.fromList(latin1.encode('%PDF-1.7\n')), format: 'pdf');
      validate(
        Uint8List.fromList(latin1.encode('prefix\n%PDF-2.0\n')),
        format: 'pdf',
      );
      expect(
        () => validate(
          Uint8List.fromList(utf8.encode('<html>PDF</html>')),
          format: 'pdf',
        ),
        invalid,
      );
      expect(
        () => validate(
          Uint8List.fromList([
            ...List.filled(1025, 32),
            ...ascii.encode('%PDF-1.7'),
          ]),
          format: 'pdf',
        ),
        invalid,
      );
    },
  );
  test('checks DWG and ASCII/binary DXF signatures', () {
    final dwg = Uint8List(128)..setAll(0, ascii.encode('AC1032'));
    validate(dwg, format: 'dwg');
    expect(() => validate(Uint8List(128), format: 'dwg'), invalid);
    validate(
      Uint8List.fromList(
        ascii.encode(
          '  0\r\nSECTION\r\n  2\r\nHEADER\r\n0\r\nENDSEC\r\n0\r\nEOF\r\n',
        ),
      ),
      format: 'dxf',
    );
    validate(
      Uint8List.fromList([
        ...latin1.encode('AutoCAD Binary DXF\r\n\x1a\x00'),
        0,
        0,
        0,
        0,
      ]),
      format: 'dxf',
    );
    expect(
      () => validate(
        Uint8List.fromList(ascii.encode('not a drawing')),
        format: 'dxf',
      ),
      invalid,
    );
  });
  test('Notability and Goodnotes enforce their own archive identity', () {
    final note = _zip({
      'My Note/Session.plist': utf8.encode(
        '<?xml version="1.0"?><plist version="1.0"><dict/></plist>',
      ),
    });
    validate(note, format: 'note');
    expect(() => validate(note, format: 'goodnotes'), invalid);
    final goodnotes = _zip({
      'index.notes.pb': [0],
    });
    validate(goodnotes, format: 'goodnotes');
    expect(() => validate(goodnotes, format: 'note'), invalid);
    expect(
      () => validate(
        _zip({
          'a/Session.plist': [0],
          'b/Session.plist': [0],
        }),
        format: 'note',
      ),
      invalid,
    );
  });
  test('notebook attachments cannot evade archive inflation budget', () {
    final note = _zip({
      'index.notes.pb': [0],
      'attachments/bomb.bin': Uint8List(25 * 1024 * 1024),
    });
    expect(() => validate(note, format: 'goodnotes'), invalid);
  });
  test('unknown formats fail explicitly', () {
    expect(
      () => validate(Uint8List.fromList([1]), format: 'unknown'),
      throwsA(
        isA<DocumentParseException>().having(
          (e) => e.code,
          'code',
          'unsupported',
        ),
      ),
    );
  });
}
