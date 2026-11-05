import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/ide/document/document_model.dart';
import 'package:baocode/ide/document/document_read.dart';
import 'package:baocode/ide/document/document_read_io.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';

Matcher _readError(String code) => throwsA(
  isA<DocumentParseException>().having((error) => error.code, 'code', code),
);

class _TextOnlyFiles with ReadWriteOnlyFiles implements IdeFileService {
  var textReads = 0;

  @override
  Future<List<IdeFile>> list(String directory) async => [];

  @override
  Future<String> read(String path, {bool force = false}) async {
    textReads++;
    throw StateError('Binary document must not use the text reader');
  }

  @override
  Future<void> write(String path, String text, {String? expectedText}) async =>
      throw StateError('A preview must not write');
}

typedef _RangePart = ({Uint8List bytes, int size});

class _RangeFiles extends _TextOnlyFiles implements IdeRangeFiles {
  _RangeFiles({required this.size, required this.onRange});

  final int size;
  final Future<_RangePart> Function(int offset, int length) onRange;
  final requests = <({int offset, int length})>[];
  Future<void>? lastCancellation;
  var sizeRequests = 0;

  @override
  Future<_RangePart> readRange(
    String path,
    int offset,
    int length, {
    Future<void>? cancel,
  }) {
    requests.add((offset: offset, length: length));
    lastCancellation = cancel;
    return onRange(offset, length);
  }

  @override
  Future<int> sizeOf(List<String> paths, {int? limit}) async {
    sizeRequests++;
    return size;
  }
}

void main() {
  test(
    'cancels a pending remote range request and forwards cancellation',
    () async {
      final cancellation = Completer<void>();
      final started = Completer<void>();
      final pending = Completer<_RangePart>();
      final files = _RangeFiles(
        size: 4,
        onRange: (_, _) {
          started.complete();
          return pending.future;
        },
      );
      final result = readDocumentBytes(
        '/remote.xlsx',
        files: files,
        cancel: cancellation.future,
      );
      final expectation = expectLater(result, _readError('cancelled'));
      await started.future.timeout(const Duration(seconds: 5));
      expect(files.lastCancellation, isNotNull);
      cancellation.complete();
      await expectation.timeout(const Duration(seconds: 5));
      await files.lastCancellation!.timeout(const Duration(seconds: 5));
      pending.complete((bytes: Uint8List(4), size: 4));
      expect(files.requests, hasLength(1));
      expect(files.textReads, 0);
    },
  );

  group('bounded document byte reads', () {
    test(
      'local input accepts the exact limit and rejects an oversized file',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'document-read-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/sample.docx');
        await file.writeAsBytes([1, 2, 3, 4]);
        expect(await readDocumentBytes(file.path, maxBytes: 4), [1, 2, 3, 4]);
        await expectLater(
          readDocumentBytes(file.path, maxBytes: 3),
          _readError('tooLarge'),
        );
        // A failed read closes its handle, including on Windows.
        await file.rename('${directory.path}/renamed.docx');
      },
    );

    test(
      'local bytes are bounded even when the file grows after its size check',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'document-grow-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/growing.docx');
        await file.writeAsBytes(List.filled(16, 1));
        var checks = 0;
        await expectLater(
          readLocalDocumentBytes(file.path, 64, () {
            // Before type lookup, after lookup, after open, then after length.
            if (++checks == 4) {
              file.writeAsBytesSync(List.filled(64, 2), mode: FileMode.append);
            }
          }),
          _readError('tooLarge'),
        );
        expect(checks, greaterThanOrEqualTo(4));
        expect(await file.length(), 80);
        await file.rename('${directory.path}/closed.docx');
      },
    );

    test(
      'an explicit mock reader never stats a local path or decodes text',
      () async {
        final files = _TextOnlyFiles();
        final received = <String>[];
        const path = '/not-a-local-file/remote.docx';
        for (final service in <IdeFileService?>[null, files]) {
          final bytes = await readDocumentBytes(
            path,
            files: service,
            maxBytes: 3,
            read: (value) async {
              received.add(value);
              return Uint8List.fromList([1, 2, 3]);
            },
          );
          expect(bytes, [1, 2, 3]);
        }
        expect(received, [path, path]);
        expect(files.textReads, 0);
      },
    );

    test('explicit transport bytes are checked after the read', () async {
      await expectLater(
        readDocumentBytes(
          '/mock.docx',
          maxBytes: 3,
          read: (_) async => Uint8List(4),
        ),
        _readError('tooLarge'),
      );
    });

    test(
      'an available size rejects an explicit read before fetching bytes',
      () async {
        final files = _RangeFiles(
          size: 100,
          onRange: (_, _) async => (bytes: Uint8List(0), size: 100),
        );
        var byteReads = 0;
        await expectLater(
          readDocumentBytes(
            '/remote.docx',
            files: files,
            maxBytes: 10,
            read: (_) async {
              byteReads++;
              return Uint8List(100);
            },
          ),
          _readError('tooLarge'),
        );
        expect(files.sizeRequests, 1);
        expect(files.requests, isEmpty);
        expect(byteReads, 0);
        expect(files.textReads, 0);
      },
    );

    test('pre-cancelled work performs no I/O', () async {
      final cancellation = Completer<void>()..complete();
      var reads = 0;
      await expectLater(
        readDocumentBytes(
          '/cancel.docx',
          cancel: cancellation.future,
          read: (_) async {
            reads++;
            return Uint8List(1);
          },
        ),
        _readError('cancelled'),
      );
      expect(reads, 0);
    });

    test('cancellation releases an in-flight transport without awaiting its result', () async {
      final cancellation = Completer<void>();
      final transport = Completer<Uint8List>();
      final started = Completer<void>();
      final result = readDocumentBytes(
        '/cancel.docx',
        cancel: cancellation.future,
        read: (_) {
          started.complete();
          return transport.future;
        },
      );
      final expectation = expectLater(result, _readError('cancelled'));
      await started.future.timeout(const Duration(seconds: 5));
      cancellation.complete();
      await expectation.timeout(const Duration(seconds: 5));
      transport.complete(Uint8List(4));
    });

    test(
      'range transport assembles bounded chunks without reading text',
      () async {
        const size = 65540;
        final files = _RangeFiles(
          size: size,
          onRange: (offset, length) async =>
              (bytes: Uint8List(offset == 0 ? 65536 : 4), size: size),
        );
        expect(
          (await readDocumentBytes(
            '/remote.xlsx',
            files: files,
            maxBytes: size,
          )).length,
          size,
        );
        expect(files.requests, [
          (offset: 0, length: 65536),
          (offset: 65536, length: 5),
        ]);
        expect(files.textReads, 0);
      },
    );

    test('range transport rejects inconsistent reported file sizes', () async {
      final files = _RangeFiles(
        size: 6,
        onRange: (offset, _) async =>
            (bytes: Uint8List(3), size: offset == 0 ? 6 : 7),
      );
      await expectLater(
        readDocumentBytes('/changing.xlsx', files: files),
        _readError('read'),
      );
      expect(files.requests, hasLength(2));
      expect(files.textReads, 0);
    });

    test(
      'range transport rejects oversized replies and premature empty chunks',
      () async {
        for (final part in [
          (bytes: Uint8List(65537), size: 65537),
          (bytes: Uint8List(5), size: 4),
          (bytes: Uint8List(0), size: 4),
          (bytes: Uint8List(0), size: -1),
        ]) {
          final files = _RangeFiles(
            size: part.size,
            onRange: (_, _) async => part,
          );
          await expectLater(
            readDocumentBytes('/bad.xlsx', files: files),
            _readError('read'),
          );
          expect(files.textReads, 0);
        }
      },
    );

    test(
      'range declared sizes and actual bytes cannot exceed the limit',
      () async {
        final files = _RangeFiles(
          size: 5,
          onRange: (_, _) async => (bytes: Uint8List(1), size: 5),
        );
        await expectLater(
          readDocumentBytes('/large.xlsx', files: files, maxBytes: 4),
          _readError('tooLarge'),
        );
        expect(files.requests, [(offset: 0, length: 5)]);
      },
    );

    test(
      'text-only hosts are rejected without a lossy binary text fallback',
      () async {
        final files = _TextOnlyFiles();
        await expectLater(
          readDocumentBytes('/binary.docx', files: files),
          _readError('read'),
        );
        expect(files.textReads, 0);
      },
    );
  });
}
