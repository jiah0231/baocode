import 'dart:async';
import 'dart:typed_data';

import 'package:baocode/ide/ide_document_preview.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart' hide ColorScheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'document_fixtures.dart';

Finder _text(String text) => find.textContaining(text, findRichText: true);

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final elapsed = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 15)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  }
  expect(finder, findsWidgets);
}

Future<void> _pump(
  WidgetTester tester, {
  String path = '/project/document.docx',
  required Future<Uint8List> Function(String) read,
  int revision = 0,
  bool historical = false,
  VoidCallback? external,
  double textScale = 1,
}) => tester.pumpWidget(
  WorkbenchThemeScope(
    builder: (_) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: IdeDocumentPreview(
          path: path,
          read: read,
          revision: revision,
          historical: historical,
          onOpenInDefaultApp: external,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('an embedded Word PNG decodes and renders in the preview', (
    tester,
  ) async {
    await _pump(tester, read: (_) async => wordImageDocument());
    final imageFinder = find.descendant(
      of: find.byType(IdeDocumentPreview),
      matching: find.byType(Image),
    );
    await _waitFor(tester, imageFinder);
    // The Image stream was created in the test's fake-async zone. Awaiting
    // precacheImage inside runAsync can deadlock its completion behind pump.
    // Poll the decoded widget with the same bounded real-time helper instead.
    await _waitFor(
      tester,
      find.descendant(
        of: imageFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
      ),
    );
    final raw = tester.widget<RawImage>(
      find.descendant(of: imageFinder, matching: find.byType(RawImage)),
    );
    expect(raw.image, isNotNull);
    expect(_text('This image cannot be previewed'), findsNothing);
    expect(_text('Image caption'), findsWidgets);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Word shows Unicode text and its table as read-only content', (
    tester,
  ) async {
    // The preceding preview completed in a different test zone. An idle
    // global parse queue must not retain that zone's completed Future.
    var reads = 0;
    await _pump(
      tester,
      read: (_) async {
        reads++;
        return wordDocument();
      },
    );
    await _waitFor(tester, _text('Hello 世界 & friends'));
    expect(reads, 1);
    expect(_text('Apples'), findsWidgets);
    expect(find.text('Read only · Offline'), findsOneWidget);
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .every((text) => text.readOnly),
      isTrue,
    );
    expect(find.text('Open in default app'), findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('PowerPoint navigation follows the saved slide order', (
    tester,
  ) async {
    await _pump(
      tester,
      path: '/project/slides.pptx',
      read: (_) async => slideDocument(),
    );
    await _waitFor(tester, find.text('1 / 2'));
    expect(_text('First slide 第一页'), findsWidgets);
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(_text('Second slide 第二页'), findsWidgets);
    await tester.tap(find.text('Previous'));
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.text('Reading view'));
    await tester.pump();
    expect(find.text('Slide layout'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Excel sheet tabs switch without reading the file again', (
    tester,
  ) async {
    var reads = 0;
    await _pump(
      tester,
      path: '/project/budget.xlsx',
      read: (_) async {
        reads++;
        return spreadsheetDocument();
      },
    );
    await _waitFor(tester, find.text('预算 Budget'));
    expect(_text('收入 Revenue'), findsWidgets);
    await tester.tap(find.text('Notes'));
    await tester.pump();
    expect(_text('Private notes'), findsWidgets);
    await tester.tap(find.text('预算 Budget'));
    await tester.pump();
    expect(_text('收入 Revenue'), findsWidgets);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('CSV and TSV show a grid rather than an editable text document', (
    tester,
  ) async {
    for (final extension in ['csv', 'tsv']) {
      final delimiter = extension == 'csv' ? ',' : '\t';
      await _pump(
        tester,
        path: '/project/data.$extension',
        read: (_) async =>
            csvDocument('Name${delimiter}Value\n张${delimiter}42\n'),
      );
      await _waitFor(tester, _text('张'));
      expect(
        tester
            .widgetList<EditableText>(find.byType(EditableText))
            .every((text) => text.readOnly),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a sparse spreadsheet virtualizes both axes', (tester) async {
    await _pump(
      tester,
      path: '/project/sparse.xlsx',
      read: (_) async => spreadsheetDocument(
        firstSheet:
            '<worksheet xmlns="http://schemas.openxmlformats.org/'
            'spreadsheetml/2006/main"><sheetData><row r="1048576">'
            '<c r="XFD1048576" t="inlineStr"><is><t>Last cell</t></is></c>'
            '</row></sheetData></worksheet>',
      ),
    );
    await _waitFor(tester, _text('1048576 rows × 16384 columns'));
    expect(find.byType(EditableText).evaluate().length, lessThan(250));
    expect(_text('Last cell'), findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a slower file cannot replace a newer selection', (tester) async {
    final first = Completer<Uint8List>();
    final calls = <String>[];
    Future<Uint8List> read(String path) {
      calls.add(path);
      return path.endsWith('first.docx')
          ? first.future
          : Future.value(wordDocument(text: 'Newer content'));
    }

    await _pump(tester, path: '/project/first.docx', read: read);
    await _pump(tester, path: '/project/second.docx', read: read);
    await _waitFor(tester, _text('Newer content'));
    first.complete(wordDocument(text: 'Stale content'));
    await tester.pump();
    expect(_text('Newer content'), findsWidgets);
    expect(_text('Stale content'), findsNothing);
    expect(calls, ['/project/first.docx', '/project/second.docx']);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('closing during a read does not update a disposed preview', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    await _pump(tester, read: (_) => pending.future);
    await tester.pumpWidget(const SizedBox());
    pending.complete(wordDocument());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a new revision reloads the same path', (tester) async {
    var reads = 0;
    Future<Uint8List> read(String _) async =>
        wordDocument(text: 'Revision ${++reads}');
    await _pump(tester, read: read);
    await _waitFor(tester, _text('Revision 1'));
    await _pump(tester, read: read, revision: 1);
    await _waitFor(tester, _text('Revision 2'));
    expect(_text('Revision 1'), findsNothing);
    expect(reads, 2);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('replacing the byte reader reloads the same path', (
    tester,
  ) async {
    await _pump(tester, read: (_) async => wordDocument(text: 'First host'));
    await _waitFor(tester, _text('First host'));
    await _pump(tester, read: (_) async => wordDocument(text: 'Second host'));
    await _waitFor(tester, _text('Second host'));
    expect(_text('First host'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('read errors offer retry and recover without reopening the tab', (
    tester,
  ) async {
    var reads = 0;
    await _pump(
      tester,
      read: (_) async {
        if (++reads == 1) throw StateError('remote disconnected');
        return wordDocument(text: 'Recovered document');
      },
    );
    await _waitFor(tester, find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await _waitFor(tester, _text('Recovered document'));
    expect(find.text('Try again'), findsNothing);
    expect(reads, 2);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
    'reload can be clicked repeatedly while a previous load is pending',
    (tester) async {
      final reads = <Completer<Uint8List>>[];
      await _pump(
        tester,
        read: (_) {
          final pending = Completer<Uint8List>();
          reads.add(pending);
          return pending.future;
        },
      );
      await tester.tap(find.text('Reload'));
      await tester.pump();
      await tester.tap(find.text('Reload'));
      await tester.pump();
      expect(reads, hasLength(3));
      reads.last.complete(wordDocument(text: 'Latest reload'));
      await _waitFor(tester, _text('Latest reload'));
      reads[0].complete(wordDocument(text: 'Stale first reload'));
      reads[1].completeError(StateError('stale failure'));
      await tester.pump();
      expect(_text('Latest reload'), findsWidgets);
      expect(find.text('Try again'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('legacy and historical previews do not read the working file', (
    tester,
  ) async {
    var reads = 0;
    Future<Uint8List> read(String _) async {
      reads++;
      return wordDocument();
    }

    await _pump(tester, path: '/project/old.doc', read: read);
    expect(_text('Legacy Office binaries'), findsOneWidget);
    await _pump(
      tester,
      path: '/project/document.docx',
      read: read,
      historical: true,
    );
    expect(_text('Historical versions'), findsOneWidget);
    expect(reads, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
    'opening externally is offered only when an explicit callback is provided',
    (tester) async {
      var opened = 0;
      await _pump(
        tester,
        path: '/project/old.xls',
        read: (_) async => Uint8List(0),
        external: () => opened++,
      );
      await tester.tap(find.text('Open in default app'));
      expect(opened, 1);
      await _pump(
        tester,
        path: '/project/old.xls',
        read: (_) async => Uint8List(0),
      );
      expect(find.text('Open in default app'), findsNothing);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('chrome follows themes while document colors remain original', (
    tester,
  ) async {
    final original = WorkbenchThemeService.instance;
    addTearDown(() => WorkbenchThemeService.instance = original);
    Future<Uint8List> read(String _) async => wordDocument();
    final backgrounds = <Color>[];
    for (final theme in [
      'Bao Light',
      'Bao Dark',
      'Default High Contrast',
      'Default High Contrast Light',
    ]) {
      WorkbenchThemeService.instance = WorkbenchThemeService()
        ..restore(setting: theme);
      await _pump(tester, read: read);
      await _waitFor(tester, _text('Hello 世界 & friends'));
      final boxes = tester.widgetList<ColoredBox>(
        find.descendant(
          of: find.byType(IdeDocumentPreview),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(boxes.map((box) => box.color), contains(AppColors.code));
      expect(
        tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((text) => text.style?.color),
        everyElement(const Color(0xff202020)),
      );
      backgrounds.add(AppColors.code);
      expect(tester.takeException(), isNull);
    }
    expect(backgrounds[0], isNot(backgrounds[1]));
    await tester.tap(find.text('Theme colors'));
    await tester.pump();
    expect(find.text('Original colors'), findsOneWidget);
    await tester.tap(find.text('Original colors'));
    await tester.pump();
    expect(find.text('Theme colors'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('toolbar and content fit a narrow pane at larger text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      path: '/project/slides.pptx',
      read: (_) async => slideDocument(),
      textScale: 1.5,
    );
    await _waitFor(tester, find.text('1 / 2'));
    await tester.tap(find.text('Reading view'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
