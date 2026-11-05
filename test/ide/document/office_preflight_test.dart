import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/ide/document/document_model.dart';
import 'package:baocode/ide/document/office_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

import '../document_fixtures.dart';

Matcher _error(String code) =>
    throwsA(isA<DocumentParseException>().having((e) => e.code, 'code', code));

void main() {
  final fixtureRoot = Directory('test/fixtures/office_preview');
  final manifest = jsonDecode(
    File('${fixtureRoot.path}/manifest.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final entry in manifest['fixtures'] as List<dynamic>) {
    final fixture = entry as Map<String, dynamic>;
    test('preflight accepts unchanged visual fixture ${fixture['id']}', () {
      final path = '${fixtureRoot.path}/${fixture['path']}';
      final bytes = File(path).readAsBytesSync();
      final before = Uint8List.fromList(bytes);
      validateOfficePreview(path: path, bytes: bytes);
      expect(bytes, orderedEquals(before));
    });
  }

  test('all three Office packages validate without rewriting their bytes', () {
    for (final (path, bytes) in [
      ('layout.docx', wordImageDocument()),
      ('layout.pptx', positionedSlideDocument(grouped: true)),
      ('layout.xlsx', spreadsheetDocument()),
    ]) {
      final before = Uint8List.fromList(bytes);
      validateOfficePreview(path: path, bytes: bytes);
      expect(bytes, orderedEquals(before));
    }
  });

  test(
    'empty, encrypted and non-Office inputs fail before renderer handoff',
    () {
      expect(
        () => validateOfficePreview(path: 'x.docx', bytes: Uint8List(0)),
        _error('empty'),
      );
      expect(
        () => validateOfficePreview(
          path: 'x.xlsx',
          bytes: Uint8List.fromList([
            0xd0,
            0xcf,
            0x11,
            0xe0,
            0xa1,
            0xb1,
            0x1a,
            0xe1,
          ]),
        ),
        _error('encrypted'),
      );
      expect(
        () => validateOfficePreview(path: 'x.csv', bytes: wordDocument()),
        _error('unsupported'),
      );
    },
  );

  test('unreferenced XML parts are validated too', () {
    final bytes = wordDocument(
      extraEntries: {
        'customXml/unreferenced.xml':
            '<!DOCTYPE x [<!ENTITY x "unsafe">]><x>&x;</x>',
      },
    );
    expect(
      () => validateOfficePreview(path: 'x.docx', bytes: bytes),
      _error('corrupt'),
    );
  });

  test('unreferenced raster images obey decoded pixel limits', () {
    final bytes = wordImageDocument();
    expect(
      () => validateOfficePreview(
        path: 'x.docx',
        bytes: bytes,
        limits: const DocumentPreviewLimits(maxImagePixels: 0),
      ),
      _error('tooLarge'),
    );
  });

  test(
    'opaque parts obey inflated budgets even when no renderer uses them',
    () {
      final bytes = wordDocument(
        extraEntries: {'word/fonts/unused.bin': Uint8List(4096)},
      );
      expect(
        () => validateOfficePreview(
          path: 'x.docx',
          bytes: bytes,
          limits: const DocumentPreviewLimits(maxEntryBytes: 2048),
        ),
        _error('tooLarge'),
      );
    },
  );

  test('compressed input size is checked before package decoding', () {
    expect(
      () => validateOfficePreview(
        path: 'x.docx',
        bytes: wordDocument(),
        limits: const DocumentPreviewLimits(maxCompressedBytes: 1),
      ),
      _error('tooLarge'),
    );
  });
}
