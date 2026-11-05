import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../file_service.dart';
import '../file_service_stub.dart'
    if (dart.library.io) '../file_service_io.dart'
    as files_platform;
import 'document_model.dart';
import 'document_read_stub.dart'
    if (dart.library.io) 'document_read_io.dart'
    as platform;

/// Reads Office bytes without the text editor's lossy binary fallback.
/// Explicit readers are trusted transports, checked before and after reading;
/// built-in local/range transports never request more than the preview limit.
Future<Uint8List> readDocumentBytes(
  String path, {
  IdeFileService? files,
  Future<Uint8List> Function(String)? read,
  int maxBytes = 32 * 1024 * 1024,
  Future<void>? cancel,
}) async {
  if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  var cancelled = false;
  final cancellation = cancel?.then<void>(
    (_) => cancelled = true,
    onError: (Object _, StackTrace _) => cancelled = true,
  );
  void check() {
    if (cancelled) {
      throw const DocumentParseException(
        'Preview cancelled.',
        code: 'cancelled',
      );
    }
  }

  Future<T> wait<T>(Future<T> operation) async {
    if (cancellation == null) return operation;
    return Future.any<T>([
      operation,
      cancellation.then<T>(
        (_) => throw const DocumentParseException(
          'Preview cancelled.',
          code: 'cancelled',
        ),
      ),
    ]);
  }

  void checkSize(int size) {
    if (size < 0) {
      throw const DocumentParseException(
        'Invalid document size.',
        code: 'read',
      );
    }
    if (size > maxBytes) {
      throw const DocumentParseException(
        'Document exceeds the preview size limit.',
        code: 'tooLarge',
      );
    }
  }

  try {
    // Let an already completed cancellation prevent the first I/O operation.
    await Future<void>.value();
    check();
    if (read != null) {
      final size = files == null ? null : byteSizeThrough(files, path);
      if (size != null) checkSize(await wait(size));
      check();
      final bytes = await wait(read(path));
      check();
      checkSize(bytes.length);
      return bytes;
    }
    if (files == null || files is files_platform.LocalIdeFileService) {
      return await platform.readLocalDocumentBytes(path, maxBytes, check);
    }
    if (files case final IdeRangeFiles ranges) {
      // Coalesce even pathological tiny host chunks instead of retaining one
      // list object per byte. Bound round trips independently from file size.
      final builder = BytesBuilder(copy: true);
      final maxReads = math.max(1024, (maxBytes ~/ (64 * 1024) + 1) * 4);
      var reads = 0;
      int? expectedSize;
      var offset = 0;
      while (true) {
        check();
        if (++reads > maxReads) {
          throw const DocumentParseException(
            'Document host returned too many partial reads.',
            code: 'read',
          );
        }
        final length = math.min(64 * 1024, maxBytes - offset + 1);
        final part = await wait(
          ranges.readRange(path, offset, length, cancel: cancellation),
        );
        check();
        checkSize(part.size);
        if (part.bytes.length > length ||
            part.bytes.length > part.size - offset ||
            (expectedSize != null && expectedSize != part.size)) {
          throw const DocumentParseException(
            'Document changed during reading.',
            code: 'read',
          );
        }
        expectedSize = part.size;
        offset += part.bytes.length;
        checkSize(offset);
        builder.add(part.bytes);
        if (offset == part.size) return builder.takeBytes();
        if (part.bytes.isEmpty) {
          throw const DocumentParseException(
            'Document read was incomplete.',
            code: 'read',
          );
        }
      }
    }
    // A text-only service or an unbounded remote byte API cannot safely read
    // arbitrary Office files. It must supply a range transport or explicit read.
    throw const DocumentParseException(
      'This host does not support bounded document reads.',
      code: 'read',
    );
  } on DocumentParseException {
    rethrow;
  } on TransferCancelledException {
    throw const DocumentParseException('Preview cancelled.', code: 'cancelled');
  } catch (_) {
    check();
    throw const DocumentParseException(
      'The document could not be read.',
      code: 'read',
    );
  }
}
