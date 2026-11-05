import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import 'document_model.dart';
import 'document_package.dart';
export 'document_model.dart';

/// Parses only a read-only snapshot. Run this in a disposable worker isolate;
/// its synchronous ZIP/XML work must not block the Flutter UI isolate.
DocumentPreviewData parseDocumentPreview({
  required String path,
  required Uint8List bytes,
  DocumentPreviewLimits limits = const DocumentPreviewLimits(),
}) {
  final kind = documentKindForPath(path);
  if (kind == null) {
    throw const DocumentParseException(
      'This document format is not supported.',
      code: 'unsupported',
    );
  }
  if (kind == DocumentKind.legacy) {
    throw const DocumentParseException(
      'Legacy DOC, PPT and XLS files are not supported. Save a copy as DOCX, PPTX or XLSX to preview it.',
      code: 'legacy',
    );
  }
  if (bytes.length > limits.maxCompressedBytes) {
    documentTooLarge('file size');
  }
  if (bytes.isEmpty) {
    throw const DocumentParseException(
      'This document is empty.',
      code: 'empty',
    );
  }
  try {
    if (kind == DocumentKind.delimited) {
      return _delimited(path, bytes, limits);
    }
    // Encrypted OOXML uses an OLE container, not ZIP. Never attempt decryption.
    if (bytes.length >= 8 &&
        ByteData.sublistView(bytes).getUint32(0) == 0xd0cf11e0) {
      throw const DocumentParseException(
        'Password-protected or binary Office documents are not supported.',
        code: 'encrypted',
      );
    }
    final package = DocumentPackage(bytes, limits);
    return switch (kind) {
      DocumentKind.word => _word(package),
      DocumentKind.presentation => _presentation(package),
      DocumentKind.spreadsheet => _spreadsheet(package),
      _ => throw StateError('Unsupported document kind'),
    };
  } on DocumentParseException {
    rethrow;
  } catch (_) {
    // XML/ZIP diagnostics can include entire document snippets. Keep the UI
    // error safe and concise rather than exposing parser internals or content.
    throw const DocumentParseException(
      'This document is damaged or uses an unsupported format.',
    );
  }
}

DocumentPreviewData _word(DocumentPackage package) {
  if (package.limits.maxSections < 1) {
    documentTooLarge('section count');
  }
  final part = package.mainPart('word/document.xml', 'word');
  final doc = package.xml(part, required: true)!;
  final body = firstElement(doc, 'body');
  if (body == null) {
    documentCorrupt('missing Word body');
  }
  final relations = package.relationships(part);
  final blocks = <DocumentBlock>[];
  void readChildren(XmlElement parent) {
    for (final node in parent.childElements) {
      switch (node.name.local) {
        case 'p':
          package.countBlock();
          blocks.add(_wordParagraph(node, package));
          for (final drawing in elements(node, 'drawing')) {
            final blip = firstElement(drawing, 'blip');
            final extent = firstElement(drawing, 'extent');
            final image = package.image(
              relations[attr(blip, 'embed')],
              width: _emu(attr(extent, 'cx')),
              height: _emu(attr(extent, 'cy')),
            );
            if (image != null) {
              package.countBlock();
              blocks.add(image);
            }
          }
        case 'tbl':
          package.countBlock();
          final rows = <List<String>>[];
          for (final row in children(node, 'tr')) {
            final cells = <String>[];
            for (final cell in children(row, 'tc')) {
              package.countCell();
              final value = children(
                cell,
                'p',
              ).map((p) => _wordParagraph(p, package).text).join('\n');
              package.checkTextUnit(value.length);
              cells.add(value);
            }
            rows.add(cells);
          }
          blocks.add(DocumentTable(rows: rows));
          if (elements(node, 'drawing').isNotEmpty) {
            package.warnings.add('Images inside Word tables are not shown.');
          }
        case 'sdt':
        case 'sdtContent':
        case 'customXml':
          readChildren(node);
        case 'altChunk':
          package.warnings.add('Embedded HTML content is not rendered.');
      }
    }
  }

  readChildren(body);
  package.warnings.add(
    'Reading preview: pagination, floating objects, headers, footers and advanced Word layout may differ.',
  );
  return DocumentPreviewData(
    kind: DocumentKind.word,
    sections: [DocumentSection(title: 'Document', blocks: blocks)],
    warnings: package.warnings.toList(),
  );
}

DocumentParagraph _wordParagraph(
  XmlElement paragraph,
  DocumentPackage package,
) {
  final runs = <DocumentTextRun>[];
  for (final run in elements(
    paragraph,
    'r',
  ).where((r) => r.name.prefix == paragraph.name.prefix)) {
    final props = children(run, 'rPr').firstOrNull;
    final buffer = StringBuffer();
    for (final item in run.childElements) {
      switch (item.name.local) {
        case 't':
          buffer.write(item.innerText);
        case 'tab':
          buffer.write('\t');
        case 'br':
        case 'cr':
          buffer.write('\n');
      }
    }
    final text = package.text(buffer.toString());
    if (text.isEmpty) {
      continue;
    }
    runs.add(
      DocumentTextRun(
        text: text,
        bold: _on(firstElement(props, 'b')),
        italic: _on(firstElement(props, 'i')),
        underline: _on(firstElement(props, 'u')),
        fontSize: _fontSize(attr(firstElement(props, 'sz'), 'val'), 2),
        color: _color(attr(firstElement(props, 'color'), 'val')),
      ),
    );
  }
  if (runs.length > package.limits.maxParagraphRuns) {
    documentTooLarge('paragraph formatting runs');
  }
  package.checkTextUnit(runs.fold<int>(0, (sum, run) => sum + run.text.length));
  final props = children(paragraph, 'pPr').firstOrNull;
  final style = attr(firstElement(props, 'pStyle'), 'val') ?? '';
  final heading = RegExp(
    r'^heading\s*([1-6])$',
    caseSensitive: false,
  ).firstMatch(style);
  return DocumentParagraph(
    runs: runs,
    alignment: _alignment(attr(firstElement(props, 'jc'), 'val')),
    headingLevel: heading == null ? null : int.parse(heading.group(1)!),
  );
}

bool _on(XmlElement? element) =>
    element != null &&
    !{
      '0',
      'false',
      'off',
      'none',
    }.contains(attr(element, 'val')?.toLowerCase());
String _alignment(String? value) => switch (value) {
  'center' || 'ctr' => 'center',
  'right' || 'r' || 'end' => 'right',
  'both' || 'justify' || 'just' => 'justify',
  _ => 'left',
};
double? _fontSize(String? value, double divisor) {
  final parsed = double.tryParse(value ?? '');
  return parsed == null || !parsed.isFinite
      ? null
      : (parsed / divisor).clamp(6.0, 144.0);
}

int? _color(String? value) {
  if (value == null || !RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(value)) {
    return null;
  }
  return 0xff000000 | int.parse(value, radix: 16);
}

double? _emu(String? value) {
  final parsed = double.tryParse(value ?? '');
  if (parsed == null || !parsed.isFinite || parsed <= 0 || parsed > 914400000) {
    return null;
  }
  return parsed / 9525;
}

String? _relationshipId(XmlElement element) => element.attributes
    .where((a) => a.name.local == 'id' && a.name.prefix != null)
    .firstOrNull
    ?.value;

DocumentPreviewData _presentation(DocumentPackage package) {
  final part = package.mainPart('ppt/presentation.xml', 'ppt');
  final doc = package.xml(part, required: true)!;
  final relations = package.relationships(part);
  final size = firstElement(doc, 'sldSz');
  final width = _emu(attr(size, 'cx')) ?? 960;
  final height = _emu(attr(size, 'cy')) ?? 540;
  final sections = <DocumentSection>[];
  final ids = firstElement(doc, 'sldIdLst');
  if (ids == null) {
    documentCorrupt('missing slide list');
  }
  for (final id in children(ids, 'sldId')) {
    if (sections.length >= package.limits.maxSections) {
      documentTooLarge('slide count');
    }
    final relation = relations[_relationshipId(id)];
    if (relation == null ||
        !relation.type.endsWith('/slide') ||
        !relation.path.startsWith('ppt/')) {
      documentCorrupt('invalid slide relationship');
    }
    final slide = package.xml(relation.path, required: true)!;
    final slideRelations = package.relationships(relation.path);
    final blocks = <DocumentBlock>[];
    final positioned = <DocumentSlideElement>[];
    final tree = firstElement(slide, 'spTree');
    if (tree != null) {
      _slideChildren(
        tree,
        package,
        slideRelations,
        blocks,
        positioned,
        const _Transform(),
        width,
        height,
      );
    }
    final bg = firstElement(slide, 'bg');
    final title = blocks
        .whereType<DocumentParagraph>()
        .map((p) => p.text.trim())
        .firstWhere(
          (t) => t.isNotEmpty,
          orElse: () => 'Slide ${sections.length + 1}',
        );
    sections.add(
      DocumentSection(
        title: title.length > 120 ? '${title.substring(0, 120)}…' : title,
        blocks: blocks,
        elements: positioned,
        slideWidth: width,
        slideHeight: height,
        backgroundColor: _color(attr(firstElement(bg, 'srgbClr'), 'val')),
      ),
    );
  }
  package.warnings.add(
    'Slide preview: charts, SmartArt, master artwork, animations, effects and some fonts are not reproduced.',
  );
  return DocumentPreviewData(
    kind: DocumentKind.presentation,
    sections: sections,
    warnings: package.warnings.toList(),
  );
}

class _Transform {
  const _Transform({this.x = 0, this.y = 0, this.sx = 1, this.sy = 1});
  final double x, y, sx, sy;
}

double _coordinate(String? value, {double fallback = 0}) {
  final n = double.tryParse(value ?? '');
  if (n == null || !n.isFinite || n.abs() > 914400000) {
    return fallback;
  }
  return n / 9525;
}

void _slideChildren(
  XmlElement parent,
  DocumentPackage package,
  Map<String, DocumentRelationship> relations,
  List<DocumentBlock> blocks,
  List<DocumentSlideElement> positioned,
  _Transform transform,
  double slideWidth,
  double slideHeight,
) {
  for (final shape in parent.childElements) {
    if (shape.name.local == 'grpSp') {
      final props = children(shape, 'grpSpPr').firstOrNull;
      final xfrm = firstElement(props, 'xfrm');
      final off = firstElement(xfrm, 'off'), ext = firstElement(xfrm, 'ext');
      final chOff = firstElement(xfrm, 'chOff'),
          chExt = firstElement(xfrm, 'chExt');
      final ex = _coordinate(attr(ext, 'cx'), fallback: 1);
      final ey = _coordinate(attr(ext, 'cy'), fallback: 1);
      final cx = _coordinate(attr(chExt, 'cx'), fallback: ex);
      final cy = _coordinate(attr(chExt, 'cy'), fallback: ey);
      final sx = cx.abs() < .0001 ? 1.0 : ex / cx;
      final sy = cy.abs() < .0001 ? 1.0 : ey / cy;
      final grouped = _Transform(
        x:
            transform.x +
            (_coordinate(attr(off, 'x')) - _coordinate(attr(chOff, 'x')) * sx) *
                transform.sx,
        y:
            transform.y +
            (_coordinate(attr(off, 'y')) - _coordinate(attr(chOff, 'y')) * sy) *
                transform.sy,
        sx: transform.sx * sx,
        sy: transform.sy * sy,
      );
      if (![
        grouped.x,
        grouped.y,
        grouped.sx,
        grouped.sy,
      ].every((n) => n.isFinite && n.abs() < 100000)) {
        documentCorrupt('invalid group geometry');
      }
      _slideChildren(
        shape,
        package,
        relations,
        blocks,
        positioned,
        grouped,
        slideWidth,
        slideHeight,
      );
      continue;
    }
    if (!{'sp', 'pic', 'graphicFrame', 'cxnSp'}.contains(shape.name.local)) {
      continue;
    }
    final props = children(shape, 'spPr').firstOrNull;
    final xfrm =
        firstElement(props, 'xfrm') ?? children(shape, 'xfrm').firstOrNull;
    final off = firstElement(xfrm, 'off'), ext = firstElement(xfrm, 'ext');
    final x = transform.x + _coordinate(attr(off, 'x')) * transform.sx;
    final y = transform.y + _coordinate(attr(off, 'y')) * transform.sy;
    final width =
        (_coordinate(attr(ext, 'cx'), fallback: slideWidth) * transform.sx)
            .abs()
            .clamp(1.0, 20000.0);
    final height =
        (_coordinate(attr(ext, 'cy'), fallback: slideHeight / 4) * transform.sy)
            .abs()
            .clamp(1.0, 20000.0);
    if (attr(xfrm, 'rot') != null ||
        attr(xfrm, 'flipH') == '1' ||
        attr(xfrm, 'flipV') == '1') {
      package.warnings.add(
        'Rotated or flipped slide objects use a simplified layout.',
      );
    }
    final fill = _color(
      attr(
        firstElement(
          children(props ?? shape, 'solidFill').firstOrNull,
          'srgbClr',
        ),
        'val',
      ),
    );
    final line = _color(
      attr(
        firstElement(children(props ?? shape, 'ln').firstOrNull, 'srgbClr'),
        'val',
      ),
    );
    void add(DocumentBlock block) {
      if (positioned.length >= package.limits.maxSlideElements) {
        documentTooLarge('elements per slide');
      }
      package.countBlock();
      blocks.add(block);
      positioned.add(
        DocumentSlideElement(
          block: block,
          x: x.clamp(-20000.0, 20000.0),
          y: y.clamp(-20000.0, 20000.0),
          width: width,
          height: height,
          fillColor: fill,
          borderColor: line,
        ),
      );
    }

    if (shape.name.local == 'pic') {
      final blip = firstElement(shape, 'blip');
      final image = package.image(
        relations[attr(blip, 'embed')],
        width: width,
        height: height,
      );
      if (image != null) {
        add(image);
      }
      continue;
    }
    final table = firstElement(shape, 'tbl');
    if (table != null) {
      final rows = <List<String>>[];
      for (final tr in children(table, 'tr')) {
        rows.add([
          for (final tc in children(tr, 'tc')) _slideCell(tc, package),
        ]);
      }
      add(DocumentTable(rows: rows));
      continue;
    }
    final txBody = children(shape, 'txBody').firstOrNull;
    if (txBody != null) {
      // Keep a shape's paragraphs in one positioned block; adding one element
      // per paragraph at the same coordinates would paint them over each other.
      final runs = <DocumentTextRun>[];
      String alignment = 'left';
      for (final paragraph in children(txBody, 'p')) {
        if (runs.isNotEmpty) {
          runs.add(const DocumentTextRun(text: '\n'));
        }
        alignment = _alignment(
          attr(children(paragraph, 'pPr').firstOrNull, 'algn'),
        );
        for (final child in paragraph.childElements) {
          if (child.name.local == 'br') {
            runs.add(const DocumentTextRun(text: '\n'));
            continue;
          }
          if (child.name.local != 'r' && child.name.local != 'fld') {
            continue;
          }
          final props = children(child, 'rPr').firstOrNull;
          final text = package.text(
            elements(child, 't').map((t) => t.innerText).join(),
          );
          if (text.isEmpty) {
            continue;
          }
          runs.add(
            DocumentTextRun(
              text: text,
              bold: attr(props, 'b') == '1',
              italic: attr(props, 'i') == '1',
              underline: attr(props, 'u') != null && attr(props, 'u') != 'none',
              fontSize: _fontSize(attr(props, 'sz'), 100),
              color: _color(attr(firstElement(props, 'srgbClr'), 'val')),
            ),
          );
        }
      }
      if (runs.length > package.limits.maxParagraphRuns) {
        documentTooLarge('paragraph formatting runs');
      }
      package.checkTextUnit(
        runs.fold<int>(0, (sum, run) => sum + run.text.length),
      );
      add(DocumentParagraph(runs: runs, alignment: alignment));
    } else if (fill != null || line != null) {
      add(const DocumentParagraph(runs: []));
    } else if (shape.name.local == 'graphicFrame') {
      package.warnings.add('Some slide graphics are not shown.');
    }
  }
}

String _slideCell(XmlElement cell, DocumentPackage package) {
  package.countCell();
  return package.text(
    elements(
      cell,
      'p',
    ).map((p) => elements(p, 't').map((t) => t.innerText).join()).join('\n'),
  );
}

DocumentPreviewData _spreadsheet(DocumentPackage package) {
  final part = package.mainPart('xl/workbook.xml', 'xl');
  final doc = package.xml(part, required: true)!;
  final relations = package.relationships(part);
  final shared = <String>[];
  final sharedRelation = relations.values
      .where((r) => r.type.endsWith('/sharedStrings'))
      .firstOrNull;
  final sharedDoc = package.xml(sharedRelation?.path ?? 'xl/sharedStrings.xml');
  if (sharedDoc != null) {
    for (final si in elements(sharedDoc, 'si')) {
      if (shared.length >= package.limits.maxCells) {
        documentTooLarge('shared string count');
      }
      // Phonetic annotation rPh is not part of a cell's visible string.
      shared.add(
        package.text(
          si.childElements
              .where((e) => e.name.local != 'rPh')
              .map(
                (e) => e.name.local == 't'
                    ? e.innerText
                    : elements(e, 't').map((t) => t.innerText).join(),
              )
              .join(),
        ),
      );
    }
  }
  final sheets = <DocumentSheet>[];
  final sheetList = firstElement(doc, 'sheets');
  if (sheetList == null) {
    documentCorrupt('missing workbook sheets');
  }
  for (final sheet in children(sheetList, 'sheet')) {
    if ({'hidden', 'veryHidden'}.contains(attr(sheet, 'state'))) {
      package.warnings.add('Hidden worksheets are omitted from this preview.');
      continue;
    }
    if (sheets.length >= package.limits.maxSections) {
      documentTooLarge('sheet count');
    }
    final relation = relations[_relationshipId(sheet)];
    if (relation == null ||
        !relation.type.endsWith('/worksheet') ||
        !relation.path.startsWith('xl/')) {
      documentCorrupt('invalid sheet relationship');
    }
    final xml = package.xml(relation.path, required: true)!;
    final data = firstElement(xml, 'sheetData');
    final rows = <int, Map<int, DocumentCell>>{};
    var rowCount = 0, columnCount = 0, nextRow = 0;
    if (data != null) {
      for (final row in children(data, 'row')) {
        final rowIndex = attr(row, 'r') == null
            ? nextRow
            : (int.tryParse(attr(row, 'r')!) ?? 0) - 1;
        if (rowIndex < 0 || rowIndex >= 1048576) {
          documentCorrupt('invalid row coordinate');
        }
        nextRow = rowIndex + 1;
        var nextColumn = 0;
        for (final cell in children(row, 'c')) {
          final reference = attr(cell, 'r');
          final coordinate = reference == null
              ? (rowIndex, nextColumn)
              : _cellCoordinate(reference);
          if (coordinate.$1 != rowIndex) {
            documentCorrupt('cell belongs to another row');
          }
          final column = coordinate.$2;
          if (column < 0 || column >= 16384) {
            documentCorrupt('cell coordinate exceeds Excel limits');
          }
          nextColumn = column + 1;
          package.countCell();
          final raw = children(cell, 'v').firstOrNull?.innerText ?? '';
          final type = attr(cell, 't');
          String value;
          if (type == 's') {
            final index = int.tryParse(raw);
            if (index == null || index < 0 || index >= shared.length) {
              documentCorrupt('invalid shared string reference');
            }
            value = shared[index];
          } else if (type == 'inlineStr') {
            final inline = children(cell, 'is').firstOrNull;
            value = inline == null
                ? ''
                : elements(inline, 't').map((t) => t.innerText).join();
          } else if (type == 'b') {
            value = raw == '1'
                ? 'TRUE'
                : raw == '0'
                ? 'FALSE'
                : raw;
          } else {
            value = raw;
          }
          final formula = children(cell, 'f').firstOrNull?.innerText;
          final targetRow = rows.putIfAbsent(rowIndex, () => {});
          if (targetRow.containsKey(column)) {
            documentCorrupt('duplicate cell coordinate');
          }
          targetRow[column] = DocumentCell(
            text: package.text(value),
            formula: formula == null ? null : package.text(formula),
          );
          rowCount = math.max(rowCount, rowIndex + 1);
          columnCount = math.max(columnCount, column + 1);
        }
      }
    }
    if (elements(xml, 'mergeCell').isNotEmpty) {
      package.warnings.add(
        'Merged cells are shown at their original anchor cell.',
      );
    }
    sheets.add(
      DocumentSheet(
        name: package.text(attr(sheet, 'name') ?? 'Sheet ${sheets.length + 1}'),
        rows: rows,
        rowCount: rowCount,
        columnCount: columnCount,
      ),
    );
  }
  package.warnings.add(
    'Data preview: formulas are not recalculated; displayed cached values may be out of date.',
  );
  package.warnings.add(
    'Charts, drawings and cell formatting are not reproduced. Dates and numbers may appear as raw stored values.',
  );
  return DocumentPreviewData(
    kind: DocumentKind.spreadsheet,
    sheets: sheets,
    warnings: package.warnings.toList(),
  );
}

(int, int) _cellCoordinate(String value) {
  final match = RegExp(r'^([A-Za-z]{1,3})([1-9][0-9]{0,6})$').firstMatch(value);
  if (match == null) {
    documentCorrupt('invalid cell coordinate');
  }
  var column = 0;
  for (final code in match.group(1)!.toUpperCase().codeUnits) {
    column = column * 26 + code - 64;
  }
  final row = int.parse(match.group(2)!);
  if (column < 1 || column > 16384 || row > 1048576) {
    documentCorrupt('cell coordinate exceeds Excel limits');
  }
  return (row - 1, column - 1);
}

DocumentPreviewData _delimited(
  String filename,
  Uint8List bytes,
  DocumentPreviewLimits limits,
) {
  if (limits.maxSections < 1) {
    documentTooLarge('sheet count');
  }
  if (bytes.length > limits.maxTextChars * 4) {
    documentTooLarge('text');
  }
  final source = decodeDocumentText(bytes);
  if (source.length > limits.maxTextChars) {
    documentTooLarge('text');
  }
  if (source.contains('\u0000')) {
    documentCorrupt('binary data in text file');
  }
  final separator = path.extension(filename).toLowerCase() == '.tsv'
      ? '\t'
      : ',';
  final rows = <int, Map<int, DocumentCell>>{};
  var row = <int, DocumentCell>{};
  var buffer = StringBuffer();
  var r = 0, c = 0, count = 0, maxColumns = 0;
  var quoted = false, afterQuote = false, atFieldStart = true, touched = false;
  void cell() {
    if (buffer.length > limits.maxTextUnitChars) {
      documentTooLarge('cell text length');
    }
    if (++count > limits.maxCells) {
      documentTooLarge('cell count');
    }
    if (c >= 16384) {
      documentTooLarge('column count');
    }
    row[c++] = DocumentCell(text: buffer.toString());
    buffer = StringBuffer();
    atFieldStart = true;
    afterQuote = false;
  }

  void line() {
    cell();
    if (r >= 1048576) {
      documentTooLarge('row count');
    }
    rows[r++] = row;
    maxColumns = math.max(maxColumns, c);
    row = {};
    c = 0;
    touched = false;
  }

  for (var i = 0; i < source.length; i++) {
    final ch = source[i];
    touched = true;
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < source.length && source[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = false;
          afterQuote = true;
        }
      } else {
        buffer.write(ch);
      }
      continue;
    }
    if (ch == separator) {
      cell();
      continue;
    }
    if (ch == '\r' || ch == '\n') {
      if (ch == '\r' && i + 1 < source.length && source[i + 1] == '\n') {
        i++;
      }
      line();
      continue;
    }
    if (ch == '"' && atFieldStart) {
      quoted = true;
      atFieldStart = false;
      continue;
    }
    if (afterQuote) {
      documentCorrupt('unexpected character after a quoted cell');
    }
    buffer.write(ch);
    atFieldStart = false;
  }
  if (quoted) {
    documentCorrupt('unterminated quoted cell');
  }
  if (touched || c > 0 || buffer.isNotEmpty) {
    line();
  }
  return DocumentPreviewData(
    kind: DocumentKind.delimited,
    sheets: [
      DocumentSheet(
        name: path.basename(filename),
        rows: rows,
        rowCount: r,
        columnCount: maxColumns,
      ),
    ],
    warnings: const [
      'Read-only data preview. Cell contents are never executed as formulas.',
    ],
  );
}
