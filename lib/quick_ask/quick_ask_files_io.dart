import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'quick_ask_files.dart';

Future<String> readQuickAskFile(String path) async {
  const timeout = Duration(seconds: 5);
  try {
    final file = File(path);
    final stat = await file.stat().timeout(timeout);
    if (stat.type != FileSystemEntityType.file) {
      throw const QuickAskFileException(QuickAskFileFailure.unreadable);
    }
    if (stat.size > QuickAskFileContext.maxBytes) {
      throw const QuickAskFileException(QuickAskFileFailure.tooLarge);
    }
    // Bound the actual read too: the file may grow after stat. The stream's
    // timeout cancels this read, rather than leaving an unbounded read behind.
    final bytes = await file
        .openRead(0, QuickAskFileContext.maxBytes + 1)
        .timeout(timeout)
        .fold<List<int>>([], (result, chunk) => result..addAll(chunk));
    if (bytes.length > QuickAskFileContext.maxBytes) {
      throw const QuickAskFileException(QuickAskFileFailure.tooLarge);
    }
    final text = utf8.decode(bytes);
    if (text.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'))) {
      throw const QuickAskFileException(QuickAskFileFailure.notText);
    }
    if (text.length > QuickAskFileContext.maxCharacters) {
      throw const QuickAskFileException(QuickAskFileFailure.tooLarge);
    }
    return text;
  } on QuickAskFileException {
    rethrow;
  } on FormatException {
    throw const QuickAskFileException(QuickAskFileFailure.notText);
  } on Object {
    throw const QuickAskFileException(QuickAskFileFailure.unreadable);
  }
}
