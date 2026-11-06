import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/chat/side_panel/file_preview.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/ide_document_preview.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../ide/workbench/fake_files.dart';

class _RemoteFiles with ReadWriteOnlyFiles implements IdeHostFiles {
  @override
  Future<List<IdeFile>> list(String directory) async => [];

  @override
  Future<String> read(String path, {bool force = false}) async => '';

  @override
  Future<void> write(String path, String text, {String? expectedText}) async {}

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late IdeFileService files;
  const actionKey = ValueKey('document-open-default-app');

  setUp(() {
    // Keep native NoteBoard hosting out of these toolbar/launcher tests.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    directory = Directory.systemTemp.createTempSync('baocode-default-app-');
    files = IdeFileService(directory.path);
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  String localFile([String name = 'report.doc']) {
    final path = p.join(directory.path, name);
    File(path).writeAsBytesSync([1, 2, 3]);
    return path;
  }

  Widget view(
    FileOpenRequest request, {
    IdeFileService? service,
    Future<bool> Function(String)? open,
  }) => MaterialApp(
    home: Scaffold(
      body: FilePreview(
        request: request,
        files: service ?? files,
        // A pending byte reader avoids parsing fixture content. Legacy .doc
        // tests never read it; DOCX tests stay in their loading state.
        readBytes: (_) => Completer<Uint8List>().future,
        openInDefaultApp: open ?? (_) async => true,
      ),
    ),
  );

  IdeActionButton button(WidgetTester tester) =>
      tester.widget<IdeActionButton>(find.byKey(actionKey));

  Future<void> press(WidgetTester tester) async {
    await tester.runAsync(button(tester).onPressed! as Future<void> Function());
  }

  testWidgets('document toolbar omits its filename and opens the exact file', (
    tester,
  ) async {
    final path = localFile('20261014_TaskQ_时序检索与流形校准实验报告 copy.docx');
    final opened = <String>[];
    await tester.pumpWidget(
      view(
        FileOpenRequest(path),
        open: (path) async {
          opened.add(path);
          return true;
        },
      ),
    );
    expect(
      find.textContaining('20261014_TaskQ_', findRichText: true),
      findsNothing,
    );
    expect(button(tester).tooltip, 'Open in default app');
    expect(button(tester).onPressed, isNotNull);
    await press(tester);
    expect(opened, [path]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('remote paths never open the same-spelled local file', (
    tester,
  ) async {
    final path = localFile();
    final opened = <String>[];
    await tester.pumpWidget(
      view(
        FileOpenRequest(path),
        service: _RemoteFiles(),
        open: (path) async {
          opened.add(path);
          return true;
        },
      ),
    );
    expect(button(tester).onPressed, isNull);
    expect(button(tester).tooltip, contains('Save a local copy'));
    expect(
      tester.widget<IdeDocumentPreview>(find.byType(IdeDocumentPreview))
          .onOpenInDefaultApp,
      isNull,
    );
    expect(opened, isEmpty);
  });

  testWidgets('all historical request forms disable default-app opening', (
    tester,
  ) async {
    final path = localFile();
    for (final request in [
      FileOpenRequest(path, diff: true),
      FileOpenRequest(path, modified: () async => 'index'),
      FileOpenRequest(path, original: () async => 'previous'),
    ]) {
      await tester.pumpWidget(view(request));
      expect(button(tester).onPressed, isNull);
      expect(button(tester).tooltip, contains('historical version'));
      final preview = tester.widget<IdeDocumentPreview>(
        find.byType(IdeDocumentPreview),
      );
      expect(preview.historical, isTrue);
      expect(preview.onOpenInDefaultApp, isNull);
    }
  });

  testWidgets('missing files and directories report failure without launching', (
    tester,
  ) async {
    final opened = <String>[];
    final folder = Directory(p.join(directory.path, 'folder.doc'))..createSync();
    for (final path in [p.join(directory.path, 'missing.doc'), folder.path]) {
      await tester.pumpWidget(
        view(
          FileOpenRequest(path),
          open: (path) async {
            opened.add(path);
            return true;
          },
        ),
      );
      await press(tester);
      await tester.pump();
      expect(find.textContaining('Could not open this file'), findsOneWidget);
      expect(opened, isEmpty);
    }
  });

  testWidgets('launcher false and thrown errors are visible and retryable', (
    tester,
  ) async {
    final path = localFile();
    var calls = 0;
    await tester.pumpWidget(
      view(
        FileOpenRequest(path),
        open: (_) async {
          calls++;
          if (calls == 1) return false;
          if (calls == 2) throw StateError('No file association');
          return true;
        },
      ),
    );
    for (var attempt = 0; attempt < 3; attempt++) {
      await press(tester);
      await tester.pump();
      expect(button(tester).onPressed, isNotNull);
      expect(
        find.textContaining('Could not open this file'),
        attempt < 2 ? findsOneWidget : findsNothing,
      );
    }
    expect(calls, 3);
  });

  testWidgets('repeated presses only launch once while an open is pending', (
    tester,
  ) async {
    final started = Completer<void>();
    final result = Completer<bool>();
    var calls = 0;
    await tester.pumpWidget(
      view(
        FileOpenRequest(localFile()),
        open: (_) {
          calls++;
          started.complete();
          return result.future;
        },
      ),
    );
    final open = button(tester).onPressed! as Future<void> Function();
    await tester.runAsync(() async {
      final first = open();
      await started.future;
      await open();
      expect(calls, 1);
      result.complete(true);
      await first;
    });
    await tester.pump();
    expect(button(tester).onPressed, isNotNull);
  });

  testWidgets('a late launcher failure does not appear on another file', (
    tester,
  ) async {
    final started = Completer<void>();
    final result = Completer<bool>();
    await tester.pumpWidget(
      view(
        FileOpenRequest(localFile('first.doc')),
        open: (_) {
          started.complete();
          return result.future;
        },
      ),
    );
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = (button(tester).onPressed! as Future<void> Function())();
      await started.future;
    });
    await tester.pumpWidget(view(FileOpenRequest(localFile('second.doc'))));
    result.complete(false);
    await tester.runAsync(() => pending);
    await tester.pump();
    expect(find.textContaining('Could not open this file'), findsNothing);
    expect(button(tester).onPressed, isNotNull);
  });

  testWidgets('ordinary text keeps its filename', (
    tester,
  ) async {
    final path = localFile('notes.txt');
    await tester.pumpWidget(view(FileOpenRequest(path)));
    expect(find.textContaining('notes.txt', findRichText: true), findsOneWidget);
    expect(find.byKey(actionKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('relative paths and URLs cannot become local launch targets', (
    tester,
  ) async {
    for (final path in ['report.doc', 'https://example.com/report.doc']) {
      await tester.pumpWidget(view(FileOpenRequest(path)));
      expect(button(tester).onPressed, isNull);
    }
  });
}
