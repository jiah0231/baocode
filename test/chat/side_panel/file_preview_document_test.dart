import 'dart:async';
import 'dart:typed_data';

import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/chat/side_panel/file_preview.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/ide_code_editor.dart';
import 'package:baocode/ide/ide_document_preview.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../ide/workbench/fake_files.dart';

class _Files with ReadWriteOnlyFiles implements IdeFileService {
  final reads = <String>[];
  final writes = <String>[];

  @override
  Future<List<IdeFile>> list(String directory) async => [];

  @override
  Future<String> read(String path, {bool force = false}) async {
    reads.add(path);
    if (path.endsWith('.txt')) return 'A normal editable file';
    throw IdeBinaryFileException(path);
  }

  @override
  Future<void> write(String path, String text, {String? expectedText}) async =>
      writes.add(path);
}

void main() {
  testWidgets('Office links use the byte preview, never the text editor', (
    tester,
  ) async {
    final files = _Files();
    final bytesRead = <String>[];
    final pending = Completer<Uint8List>();
    Future<Uint8List> read(String path) {
      bytesRead.add(path);
      return pending.future;
    }

    for (final extension in ['docx', 'pptx', 'xlsx', 'csv', 'tsv']) {
      final path = '/remote/project/report.$extension';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilePreview(
              request: FileOpenRequest(path),
              files: files,
              readBytes: read,
            ),
          ),
        ),
      );
      final preview = tester.widget<IdeDocumentPreview>(
        find.byType(IdeDocumentPreview),
      );
      expect(preview.path, path);
      expect(preview.read, same(read));
      expect(preview.files, same(files));
      expect(find.byType(IdeCodeEditor), findsNothing);
      expect(files.reads, isEmpty);
      expect(files.writes, isEmpty);
    }
    expect(bytesRead, hasLength(5));
    await tester.pumpWidget(const SizedBox());
    pending.complete(Uint8List(0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'binary history cannot accidentally show the current working file',
    (tester) async {
      final files = _Files();
      var bytesRead = 0;
      var revisionsRead = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilePreview(
              request: FileOpenRequest(
                '/project/report.docx',
                diff: true,
                original: () async {
                  revisionsRead++;
                  return 'old binary';
                },
                modified: () async {
                  revisionsRead++;
                  return 'new binary';
                },
              ),
              files: files,
              readBytes: (_) async {
                bytesRead++;
                return Uint8List(0);
              },
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<IdeDocumentPreview>(find.byType(IdeDocumentPreview))
            .historical,
        isTrue,
      );
      expect(find.textContaining('Historical versions'), findsOneWidget);
      expect(files.reads, isEmpty);
      expect(bytesRead, 0);
      expect(revisionsRead, 0);
    },
  );

  testWidgets('changing from a pending document to text restores the editor', (
    tester,
  ) async {
    final files = _Files();
    final pending = Completer<Uint8List>();
    Future<void> show(String path) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            request: FileOpenRequest(path),
            files: files,
            readBytes: (_) => pending.future,
          ),
        ),
      ),
    );
    await show('/project/report.docx');
    expect(find.byType(IdeDocumentPreview), findsOneWidget);
    await show('/project/readme.txt');
    await tester.pump();
    expect(find.byType(IdeDocumentPreview), findsNothing);
    expect(find.byType(IdeCodeEditor), findsOneWidget);
    pending.complete(Uint8List(0));
    await tester.pump();
    expect(files.reads, ['/project/readme.txt']);
    expect(files.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test(
    'IDE documents open read-only and save does not write binary content',
    () async {
      final files = _Files();
      final root = p.absolute(p.join(p.separator, 'document-project'));
      final workspace = IdeWorkspace(root, files: files);
      addTearDown(workspace.dispose);
      for (final extension in [
        'docx',
        'pptx',
        'xlsx',
        'csv',
        'tsv',
        'doc',
        'ppt',
        'xls',
      ]) {
        final path = p.join(root, 'report.$extension');
        await workspace.open(path);
        final document = workspace.active!;
        expect(document.path, path);
        expect(document.isMedia, isTrue);
        expect(document.readOnly, isTrue);
        expect(document.dirty, isFalse);
        await workspace.save(document);
      }
      expect(files.reads, isEmpty);
      expect(files.writes, isEmpty);
    },
  );

  test(
    'restored Office tabs remain previews without reading binary as text',
    () async {
      final files = _Files();
      final root = p.absolute(p.join(p.separator, 'restored-documents'));
      final workspace = IdeWorkspace(root, files: files);
      addTearDown(workspace.dispose);
      final paths = [
        for (final extension in ['docx', 'pptx', 'xlsx'])
          p.join(root, 'report.$extension'),
      ];
      await workspace.restore(paths, active: paths.last);
      expect(workspace.documents.map((doc) => doc.path), paths);
      expect(
        workspace.documents.every((doc) => doc.isMedia && doc.readOnly),
        isTrue,
      );
      expect(workspace.active?.path, paths.last);
      expect(files.reads, isEmpty);
      expect(files.writes, isEmpty);
    },
  );
}
