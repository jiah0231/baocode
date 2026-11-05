import 'dart:typed_data';

import 'document_format.dart';
export 'document_format.dart';

/// Plain, isolate-sendable data. No file access, links, formulas or macros are
/// executed by a preview; these models are never written back to the source.
class DocumentPreviewData {
  const DocumentPreviewData({
    required this.kind,
    this.sections = const [],
    this.sheets = const [],
    this.warnings = const [],
  });
  final DocumentKind kind;
  final List<DocumentSection> sections;
  final List<DocumentSheet> sheets;
  final List<String> warnings;
}

class DocumentSection {
  const DocumentSection({
    required this.title,
    this.blocks = const [],
    this.slideWidth,
    this.slideHeight,
    this.elements = const [],
    this.backgroundColor,
  });
  final String title;
  final List<DocumentBlock> blocks;
  final double? slideWidth;
  final double? slideHeight;
  final int? backgroundColor;
  final List<DocumentSlideElement> elements;
}

sealed class DocumentBlock {
  const DocumentBlock();
}

class DocumentParagraph extends DocumentBlock {
  const DocumentParagraph({
    required this.runs,
    this.alignment = 'left',
    this.headingLevel,
  });
  final List<DocumentTextRun> runs;
  final String alignment;
  final int? headingLevel;
  String get text => runs.map((run) => run.text).join();
}

class DocumentTextRun {
  const DocumentTextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontSize,
    this.color,
  });
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final double? fontSize;
  final int? color;
}

class DocumentTable extends DocumentBlock {
  const DocumentTable({required this.rows});
  final List<List<String>> rows;
}

class DocumentImage extends DocumentBlock {
  const DocumentImage({
    required this.bytes,
    required this.name,
    this.width,
    this.height,
    this.pixelWidth,
    this.pixelHeight,
  });
  final Uint8List bytes;
  final String name;
  final double? width;
  final double? height;

  /// Dimensions read from the image header before it reaches the codec.
  final int? pixelWidth, pixelHeight;
}

class DocumentSlideElement {
  const DocumentSlideElement({
    required this.block,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.fillColor,
    this.borderColor,
  });
  final DocumentBlock block;

  /// Coordinates in the same pixels as the section's slideWidth/slideHeight.
  final double x, y, width, height;
  final int? fillColor, borderColor;
}

class DocumentSheet {
  const DocumentSheet({
    required this.name,
    required this.rows,
    required this.rowCount,
    required this.columnCount,
  });
  final String name;

  /// Original, zero-based coordinates. A sparse workbook never becomes a
  /// rectangular allocation, even when its last cell is XFD1048576.
  final Map<int, Map<int, DocumentCell>> rows;
  final int rowCount, columnCount;
  DocumentCell? cellAt(int row, int column) => rows[row]?[column];
}

class DocumentCell {
  const DocumentCell({required this.text, this.formula});
  final String text;

  /// Informational only. [text] is the file's cached value, not recalculated.
  final String? formula;
}

class DocumentParseException implements Exception {
  const DocumentParseException(this.message, {this.code = 'corrupt'});
  final String message;
  final String code;
  @override
  String toString() => message;
}

/// Hard limits, checked before expensive allocations. Tests may lower them.
class DocumentPreviewLimits {
  const DocumentPreviewLimits({
    this.maxCompressedBytes = 32 * 1024 * 1024,
    this.maxInflatedBytes = 96 * 1024 * 1024,
    this.maxEntryBytes = 24 * 1024 * 1024,
    this.maxXmlBytes = 16 * 1024 * 1024,
    this.maxEntries = 5000,
    this.maxXmlDepth = 96,
    this.maxXmlNodes = 500000,
    this.maxTextChars = 2000000,
    this.maxTextUnitChars = 65536,
    this.maxParagraphRuns = 2048,
    this.maxCells = 200000,
    this.maxImages = 200,
    this.maxImageBytes = 8 * 1024 * 1024,
    this.maxTotalImageBytes = 64 * 1024 * 1024,
    this.maxImagePixels = 16000000,
    this.maxTotalImagePixels = 32000000,
    this.maxSections = 200,
    this.maxBlocks = 50000,
    this.maxSlideElements = 512,
  });
  final int maxCompressedBytes, maxInflatedBytes, maxEntryBytes, maxXmlBytes;
  final int maxEntries, maxXmlDepth, maxXmlNodes, maxTextChars, maxCells;
  final int maxTextUnitChars, maxParagraphRuns;
  final int maxImages, maxImageBytes, maxTotalImageBytes, maxImagePixels;
  final int maxTotalImagePixels;
  final int maxSections, maxBlocks, maxSlideElements;
}
