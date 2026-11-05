import 'dart:typed_data';

import 'document_model.dart';
import 'document_package.dart';
import 'preview_binary_guard.dart';

/// Validate bounded ZIP/XML/image resources without transforming authored
/// content. The offline browser engines receive the exact original bytes.
void validateOfficePreview({
  required String path,
  required Uint8List bytes,
  DocumentPreviewLimits limits = const DocumentPreviewLimits(),
}) {
  if (bytes.isEmpty) {
    throw const DocumentParseException(
      'This document is empty.',
      code: 'empty',
    );
  }
  if (bytes.length > limits.maxCompressedBytes) documentTooLarge('file size');
  final format = nativeDocumentFormat(path);
  if (format == null) {
    throw const DocumentParseException(
      'This document format is not supported.',
      code: 'unsupported',
    );
  }
  if (!const {'docx', 'pptx', 'xlsx', 'epub'}.contains(format)) {
    validateBinaryPreview(
      format: format,
      bytes: bytes,
      maxBytes: limits.maxCompressedBytes,
    );
    return;
  }
  if (bytes.length >= 8 &&
      ByteData.sublistView(bytes).getUint32(0) == 0xd0cf11e0) {
    throw const DocumentParseException(
      'Password-protected Office documents are not supported.',
      code: 'encrypted',
    );
  }
  try {
    final package = DocumentPackage(bytes, limits);
    if (format == 'epub') {
      package.xml('META-INF/container.xml', required: true);
      package.validateForBrowser();
      return;
    }
    final (fallback, prefix) = switch (documentKindForPath(path)) {
      DocumentKind.word => ('word/document.xml', 'word'),
      DocumentKind.presentation => ('ppt/presentation.xml', 'ppt'),
      DocumentKind.spreadsheet => ('xl/workbook.xml', 'xl'),
      _ => throw const DocumentParseException(
        'This document format is not supported.',
        code: 'unsupported',
      ),
    };
    package.xml(package.mainPart(fallback, prefix), required: true);
    package.validateForBrowser();
  } on DocumentParseException {
    rethrow;
  } catch (_) {
    // Parser exceptions can include document contents. Never log or surface it.
    throw const DocumentParseException(
      'This document is damaged or uses an unsupported format.',
    );
  }
}
