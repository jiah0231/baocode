import 'dart:typed_data';

import 'package:baocode/ide/document/document_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../document_fixtures.dart';

DocumentPreviewData _read(
  String path,
  Uint8List bytes, {
  DocumentPreviewLimits limits = const DocumentPreviewLimits(),
}) => parseDocumentPreview(path: path, bytes: bytes, limits: limits);

List<String> _paragraphs(DocumentPreviewData preview) => [
  for (final section in preview.sections)
    for (final block in section.blocks)
      if (block is DocumentParagraph) block.text,
];

Uint8List _alterZip(
  Uint8List bytes,
  void Function(ByteData data, int offset, bool central) change,
) {
  final copy = Uint8List.fromList(bytes);
  final data = ByteData.sublistView(copy);
  for (var offset = 0; offset <= copy.length - 46; offset++) {
    final signature = data.getUint32(offset, Endian.little);
    if (signature == 0x04034b50 || signature == 0x02014b50) {
      change(data, offset, signature == 0x02014b50);
    }
  }
  return copy;
}

void main() {
  test('bounds combined paragraphs and CSV fields before text layout', () {
    expect(
      () => _read(
        'runs.docx',
        wordDocument(
          body:
              '<w:p><w:r><w:t>${'a' * 40}</w:t></w:r>'
              '<w:r><w:t>${'b' * 40}</w:t></w:r></w:p>',
        ),
        limits: const DocumentPreviewLimits(maxTextUnitChars: 64),
      ),
      throwsA(isA<DocumentParseException>()),
    );
    expect(
      () => _read(
        'field.csv',
        csvDocument('a' * 70),
        limits: const DocumentPreviewLimits(maxTextUnitChars: 64),
      ),
      throwsA(isA<DocumentParseException>()),
    );
  });

  group('document paths', () {
    test(
      'the exact bundled preview extensions match without case sensitivity',
      () {
        for (final extension in [
          'docx',
          'pptx',
          'xlsx',
          'doc',
          'ppt',
          'xls',
          'pdf',
          'epub',
          'dwg',
          'dxf',
          'note',
          'goodnotes',
        ]) {
          expect(ideIsDocumentPath('/project/report.$extension'), isTrue);
          expect(nativeDocumentFormat('/project/report.$extension'), extension);
          expect(
            ideIsDocumentPath('C:\\work\\REPORT.${extension.toUpperCase()}'),
            isTrue,
          );
        }
        for (final extension in ['csv', 'tsv', 'CSV', 'TSV']) {
          final path = '/project/report.$extension';
          expect(ideIsDocumentPath(path), isFalse);
          expect(nativeDocumentFormat(path), isNull);
          expect(documentKindForPath(path), DocumentKind.delimited);
        }
        for (final path in [
          '/project/docx',
          '/project/report.docx.txt',
          '/project/report.png',
          '/project/report.md',
          '/project/report.zip',
        ]) {
          expect(ideIsDocumentPath(path), isFalse, reason: path);
          expect(nativeDocumentFormat(path), isNull, reason: path);
        }
      },
    );

    test('old binary formats produce a clear unsupported result', () {
      final compoundFile = Uint8List.fromList([
        0xd0,
        0xcf,
        0x11,
        0xe0,
        0xa1,
        0xb1,
        0x1a,
        0xe1,
      ]);
      for (final extension in ['doc', 'ppt', 'xls']) {
        expect(
          () => _read('old.$extension', compoundFile),
          throwsA(isA<DocumentParseException>()),
        );
      }
    });
  });

  group('Word', () {
    for (final deflate in [false, true]) {
      test(
        'reads ${deflate ? 'deflated' : 'stored'} paragraphs and tables',
        () {
          final preview = _read('report.DOCX', wordDocument(deflate: deflate));
          expect(preview.kind, DocumentKind.word);
          expect(
            _paragraphs(preview),
            containsAll(['BaoCode 文档', 'Hello 世界 & friends']),
          );
          final tables = preview.sections
              .expand((section) => section.blocks)
              .whereType<DocumentTable>();
          expect(tables, hasLength(1));
          expect(tables.single.rows, [
            ['Item', 'Count'],
            ['Apples', '3'],
          ]);
        },
      );
    }

    test('preserves run order, Unicode, tabs, and line breaks', () {
      final preview = _read(
        'runs.docx',
        wordDocument(
          body:
              '<w:p><w:r><w:t xml:space="preserve">One </w:t></w:r>'
              '<w:r><w:rPr><w:b/></w:rPr><w:t>世界</w:t><w:tab/>'
              '<w:t>Two</w:t><w:br/><w:t>Three</w:t></w:r></w:p>',
        ),
      );
      expect(_paragraphs(preview).single, 'One 世界\tTwo\nThree');
    });

    test('external relationships and macro data are inert', () {
      final preview = _read(
        'external.docx',
        wordDocument(
          body:
              '<w:p><w:hyperlink r:id="external">'
              '<w:r><w:t>Visible link</w:t></w:r></w:hyperlink></w:p>',
          extraEntries: {
            'word/_rels/document.xml.rels':
                '<Relationships xmlns="http://schemas.openxmlformats.org/'
                'package/2006/relationships">'
                '<Relationship Id="external" Type="http://schemas.'
                'openxmlformats.org/officeDocument/2006/relationships/hyperlink" '
                'Target="https://example.invalid/private" TargetMode="External"/>'
                '</Relationships>',
            'word/vbaProject.bin': 'not executable; must never be loaded',
          },
        ),
      );
      expect(_paragraphs(preview), contains('Visible link'));
    });
  });

  group('embedded images and slide geometry', () {
    test(
      'Word resolves image relationships and preserves display and pixel sizes',
      () {
        final preview = _read('image.docx', wordImageDocument());
        final image = preview.sections.single.blocks
            .whereType<DocumentImage>()
            .single;
        expect(image.name, 'pixel.png');
        expect(image.bytes, documentPng());
        expect(image.width, 200);
        expect(image.height, 100);
        expect(image.pixelWidth, 1);
        expect(image.pixelHeight, 1);
        expect(_paragraphs(preview), contains('Image caption'));
      },
    );

    test('PowerPoint preserves picture and text ordering, geometry and authored colors', () {
      final preview = _read('positioned.pptx', positionedSlideDocument());
      final slide = preview.sections.first;
      expect(slide.slideWidth, 1280);
      expect(slide.slideHeight, 720);
      expect(slide.backgroundColor, 0xff102030);
      expect(slide.elements, hasLength(2));
      final image = slide.elements.first;
      expect(image.block, isA<DocumentImage>());
      expect([image.x, image.y, image.width, image.height], [10, 20, 100, 50]);
      final picture = image.block as DocumentImage;
      expect(picture.bytes, documentPng());
      expect([picture.pixelWidth, picture.pixelHeight], [1, 1]);
      expect([picture.width, picture.height], [100, 50]);
      final text = slide.elements.last;
      expect([text.x, text.y, text.width, text.height], [30, 40, 200, 60]);
      expect(text.fillColor, 0xffaabbcc);
      expect(text.borderColor, 0xff112233);
      final paragraph = text.block as DocumentParagraph;
      expect(paragraph.text, 'Positioned text');
      expect(paragraph.alignment, 'center');
      expect(paragraph.runs.single.bold, isTrue);
      expect(paragraph.runs.single.fontSize, 24);
      expect(paragraph.runs.single.color, 0xff445566);
      expect(slide.blocks.first, same(image.block));
      expect(slide.blocks.last, same(text.block));
    });

    test(
      'grouped slide objects use child coordinates and nonuniform scaling',
      () {
        final preview = _read(
          'grouped.pptx',
          positionedSlideDocument(grouped: true),
        );
        final elements = preview.sections.first.elements;
        expect(elements, hasLength(2));
        expect(
          [
            elements.first.x,
            elements.first.y,
            elements.first.width,
            elements.first.height,
          ],
          [100, 200, 200, 150],
        );
        expect(
          [
            elements.last.x,
            elements.last.y,
            elements.last.width,
            elements.last.height,
          ],
          [140, 260, 400, 180],
        );
      },
    );

    test('slide element budget applies inside and outside groups', () {
      for (final grouped in [false, true]) {
        expect(
          () => _read(
            'crowded.pptx',
            positionedSlideDocument(grouped: grouped),
            limits: const DocumentPreviewLimits(maxSlideElements: 1),
          ),
          throwsA(
            isA<DocumentParseException>().having(
              (e) => e.code,
              'code',
              'tooLarge',
            ),
          ),
        );
      }
    });

    test('small fixtures exercise image byte, pixel and count limits', () {
      final bytes = wordImageDocument();
      for (final limits in [
        DocumentPreviewLimits(maxImageBytes: documentPng().length - 1),
        DocumentPreviewLimits(maxTotalImageBytes: documentPng().length - 1),
        const DocumentPreviewLimits(maxImagePixels: 0),
        const DocumentPreviewLimits(maxTotalImagePixels: 0),
        const DocumentPreviewLimits(maxImages: 0),
      ]) {
        expect(
          () => _read('image.docx', bytes, limits: limits),
          throwsA(
            isA<DocumentParseException>().having(
              (e) => e.code,
              'code',
              'tooLarge',
            ),
          ),
        );
      }
    });
  });

  group('PowerPoint', () {
    test(
      'uses presentation relationships, not filename or archive ordering',
      () {
        final preview = _read('slides.pptx', slideDocument());
        expect(preview.kind, DocumentKind.presentation);
        expect(preview.sections, hasLength(2));
        expect(_paragraphs(preview), ['First slide 第一页', 'Second slide 第二页']);
      },
    );
  });

  group('Excel', () {
    test(
      'retains sheet order, shared strings, sparse cells and cached values',
      () {
        final preview = _read('budget.xlsx', spreadsheetDocument());
        expect(preview.kind, DocumentKind.spreadsheet);
        expect(preview.sheets.map((sheet) => sheet.name), [
          '预算 Budget',
          'Notes',
        ]);
        final sheet = preview.sheets.first;
        expect(sheet.cellAt(0, 0)?.text, '收入 Revenue');
        expect(sheet.cellAt(0, 1), isNull);
        expect(sheet.cellAt(0, 2)?.text, '42.5');
        expect(sheet.cellAt(0, 3)?.text.toLowerCase(), 'true');
        expect(sheet.cellAt(2, 0)?.text, 'Rich text');
        expect(sheet.cellAt(2, 1)?.text, '43.5');
        expect(sheet.cellAt(2, 1)?.formula, 'SUM(C1,1)');
        expect(sheet.rowCount, 3);
        expect(sheet.columnCount, 4);
        expect(preview.sheets.last.cellAt(0, 0)?.text, 'Private notes');
      },
    );

    test(
      'a far corner cell remains sparse rather than allocating a matrix',
      () {
        final preview = _read(
          'sparse.xlsx',
          spreadsheetDocument(
            firstSheet:
                '<worksheet xmlns="http://schemas.openxmlformats.org/'
                'spreadsheetml/2006/main"><sheetData><row r="1048576">'
                '<c r="XFD1048576" t="inlineStr"><is><t>Last cell</t></is></c>'
                '</row></sheetData></worksheet>',
          ),
        );
        final sheet = preview.sheets.first;
        expect(sheet.rows, hasLength(1));
        expect(sheet.rows.values.single, hasLength(1));
        expect(sheet.cellAt(1048575, 16383)?.text, 'Last cell');
        expect(sheet.rowCount, 1048576);
        expect(sheet.columnCount, 16384);
      },
    );

    test('does not execute formulas without cached values', () {
      final preview = _read(
        'formula.xlsx',
        spreadsheetDocument(
          firstSheet:
              '<worksheet xmlns="http://schemas.openxmlformats.org/'
              'spreadsheetml/2006/main"><sheetData><row r="1">'
              '<c r="A1"><f>WEBSERVICE("https://example.invalid/")</f></c>'
              '</row></sheetData></worksheet>',
        ),
      );
      final cell = preview.sheets.first.cellAt(0, 0)!;
      expect(cell.formula, 'WEBSERVICE("https://example.invalid/")');
      expect(cell.text, anyOf('', '=WEBSERVICE("https://example.invalid/")'));
    });
  });

  group('CSV and TSV', () {
    test(
      'handles BOM, quoted separators, escaped quotes and embedded newlines',
      () {
        final preview = _read(
          'data.csv',
          csvDocument(
            '\ufeffName,Notes,Value\r\n'
            '"Alice, 张","said ""hello""\nnext",42\r\n',
          ),
        );
        expect(preview.kind, DocumentKind.delimited);
        final sheet = preview.sheets.single;
        expect(sheet.cellAt(0, 0)?.text, 'Name');
        expect(sheet.cellAt(1, 0)?.text, 'Alice, 张');
        expect(sheet.cellAt(1, 1)?.text, 'said "hello"\nnext');
        expect(sheet.cellAt(1, 2)?.text, '42');
      },
    );

    test('TSV preserves empty fields and formula-looking text', () {
      final preview = _read(
        'data.TSV',
        csvDocument(
          'Name\t\tValue\n'
          '张\t=1+1\t3\n',
        ),
      );
      final sheet = preview.sheets.single;
      expect(sheet.cellAt(0, 1)?.text ?? '', '');
      expect(sheet.cellAt(1, 0)?.text, '张');
      expect(sheet.cellAt(1, 1)?.text, '=1+1');
      expect(sheet.cellAt(1, 1)?.formula, isNull);
    });
  });

  group('untrusted packages', () {
    test('rejects invalid, truncated and mismatched Office files', () {
      final good = wordDocument();
      for (final bytes in [
        Uint8List(0),
        csvDocument('not a ZIP'),
        Uint8List.sublistView(good, 0, good.length - 10),
        spreadsheetDocument(),
      ]) {
        expect(
          () => _read('broken.docx', bytes),
          throwsA(isA<DocumentParseException>()),
        );
      }
    });

    test('rejects XML DTDs and entity declarations', () {
      final bytes = wordDocument(
        extraEntries: {
          'word/document.xml':
              '<?xml version="1.0"?>'
              '<!DOCTYPE w:document [<!ENTITY secret SYSTEM '
              '"file:///private/should-not-be-read">]>'
              '<w:document xmlns:w="http://schemas.openxmlformats.org/'
              'wordprocessingml/2006/main"><w:body><w:p><w:r>'
              '<w:t>&secret;</w:t></w:r></w:p></w:body></w:document>',
        },
      );
      expect(
        () => _read('entity.docx', bytes),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test('rejects encrypted ZIP entries before their contents are decoded', () {
      final bytes = _alterZip(wordDocument(), (data, offset, central) {
        final flags = offset + (central ? 8 : 6);
        data.setUint16(
          flags,
          data.getUint16(flags, Endian.little) | 1,
          Endian.little,
        );
      });
      expect(
        () => _read('encrypted.docx', bytes),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test(
      'rejects entries whose inflated size disagrees with their declaration',
      () {
        final bytes = _alterZip(wordDocument(), (data, offset, central) {
          data.setUint32(offset + (central ? 24 : 22), 1, Endian.little);
        });
        expect(
          () => _read('false-size.docx', bytes),
          throwsA(isA<DocumentParseException>()),
        );
      },
    );

    test('rejects absolute and traversal archive paths', () {
      for (final name in [
        '../escape.xml',
        '/absolute.xml',
        'word/../../out.xml',
      ]) {
        final bytes = wordDocument(extraEntries: {name: '<ignored/>'});
        expect(
          () => _read('paths.docx', bytes),
          throwsA(isA<DocumentParseException>()),
          reason: name,
        );
      }
    });

    test('checks compressed input size before decoding', () {
      expect(
        () => _read(
          'large.docx',
          wordDocument(),
          limits: const DocumentPreviewLimits(maxCompressedBytes: 32),
        ),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test('checks entry count before parsing XML', () {
      expect(
        () => _read(
          'many.docx',
          wordDocument(),
          limits: const DocumentPreviewLimits(maxEntries: 2),
        ),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test('checks uncompressed entry and aggregate limits', () {
      final bytes = wordDocument(text: 'x' * 1000);
      for (final limits in [
        const DocumentPreviewLimits(maxEntryBytes: 64),
        const DocumentPreviewLimits(maxInflatedBytes: 128),
        const DocumentPreviewLimits(maxXmlBytes: 64),
      ]) {
        expect(
          () => _read('large.docx', bytes, limits: limits),
          throwsA(isA<DocumentParseException>()),
        );
      }
    });

    test('rejects deeply nested XML', () {
      final bytes = wordDocument(
        body:
            '${'<w:sdt>' * 20}<w:p><w:r><w:t>Deep</w:t></w:r></w:p>'
            '${'</w:sdt>' * 20}',
      );
      expect(
        () => _read(
          'deep.docx',
          bytes,
          limits: const DocumentPreviewLimits(maxXmlDepth: 8),
        ),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test(
      'rejects excessive text, cells, and sections without partial success',
      () {
        expect(
          () => _read(
            'text.docx',
            wordDocument(text: 'x' * 200),
            limits: const DocumentPreviewLimits(maxTextChars: 32),
          ),
          throwsA(isA<DocumentParseException>()),
        );
        expect(
          () => _read(
            'cells.xlsx',
            spreadsheetDocument(),
            limits: const DocumentPreviewLimits(maxCells: 2),
          ),
          throwsA(isA<DocumentParseException>()),
        );
        expect(
          () => _read(
            'slides.pptx',
            slideDocument(),
            limits: const DocumentPreviewLimits(maxSections: 1),
          ),
          throwsA(isA<DocumentParseException>()),
        );
      },
    );
  });
}
