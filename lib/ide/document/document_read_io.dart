import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'document_model.dart';

Future<Uint8List> readLocalDocumentBytes(
  String path,
  int maxBytes,
  void Function() checkCancelled,
) async {
  checkCancelled();
  final type = await FileSystemEntity.type(path, followLinks: true);
  checkCancelled();
  if (type != FileSystemEntityType.file) {
    throw const DocumentParseException(
      'Only regular files can be previewed.',
      code: 'read',
    );
  }
  final file = await File(path).open();
  try {
    checkCancelled();
    if (await file.length() > maxBytes) {
      throw const DocumentParseException(
        'Document exceeds the preview size limit.',
        code: 'tooLarge',
      );
    }
    final builder = BytesBuilder(copy: false);
    var size = 0;
    while (true) {
      checkCancelled();
      // Read through the same handle and bound actual bytes, including one
      // sentinel byte, even if another process grows/replaces the path.
      final chunk = await file.read(math.min(64 * 1024, maxBytes - size + 1));
      checkCancelled();
      size += chunk.length;
      if (size > maxBytes) {
        throw const DocumentParseException(
          'Document exceeds the preview size limit.',
          code: 'tooLarge',
        );
      }
      if (chunk.isEmpty) return builder.takeBytes();
      builder.add(chunk);
    }
  } finally {
    await file.close();
  }
}
