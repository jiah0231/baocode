import 'dart:typed_data';

import 'document_model.dart';

Future<Uint8List> readLocalDocumentBytes(
  String path,
  int maxBytes,
  void Function() checkCancelled,
) async {
  checkCancelled();
  throw const DocumentParseException(
    'Local document reads require the desktop app.',
    code: 'read',
  );
}
