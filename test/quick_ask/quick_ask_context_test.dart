import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  QuickAskContext capture(String text, int start, int end) =>
      QuickAskContext.fromText(
        text: text,
        selection: TextSelection(baseOffset: start, extentOffset: end),
        sourceLabel: 'example.dart',
        applyReplacement: (_) => true,
      );

  EditorSurfaceController editor(String text, int start, int end) {
    final document = EditorDocumentModel(text);
    final controller = EditorSurfaceController(document: document)
      ..select(start, end);
    addTearDown(() {
      controller.dispose();
      document.dispose();
    });
    return controller;
  }

  test('capture keeps selection and only its bounded neighborhood', () {
    final text = '${'before ' * 1200}selected${' after' * 1200}';
    final start = text.indexOf('selected');
    final result = capture(text, start + 8, start);
    expect(result.selectedText, 'selected');
    expect(result.contextText.length, lessThanOrEqualTo(4000));
    expect(result.contextText, contains('[selection]'));
    expect(result.contextText, isNot(contains('selected')));
    expect(result.truncated, isFalse);
    expect(result.canApply, isTrue);
  });

  test('oversized selection is clipped and cannot be applied', () {
    final result = capture('a' * 9000, 0, 9000);
    expect(result.selectedText.length, 8000);
    expect(result.truncated, isTrue);
    expect(result.canApply, isFalse);
    expect(result.applyReplacement, isNull);
    expect(capture('a' * 8000, 0, 8000).canApply, isTrue);
  });

  test('clipping preserves surrogate pairs', () {
    final result = capture('${'a' * 7999}😀tail', 0, 8005);
    expect(result.selectedText, 'a' * 7999);
    expect(result.truncated, isTrue);
    expect(QuickAskContext.prefix('a😀b', 2), 'a');
    expect(QuickAskContext.suffix('a😀b', 2), 'b');
    final around = capture('${'a' * 1999}😀${'b' * 5000}', 0, 0);
    expect(around.contextText.runes, isNot(contains(0xfffd)));
    expect(around.contextText.length, lessThanOrEqualTo(4000));
  });

  test('a caret has neighborhood but no replacement target', () {
    final result = capture('a' * 10000, 5000, 5000);
    expect(result.selectedText, isEmpty);
    expect(result.contextText.length, 4000);
    expect(result.applyReplacement, isNull);
    expect(capture('abc', -1, -1).selectedText, isEmpty);
    expect(capture('abc', 1, 50).applyReplacement, isNull);
  });

  test(
    'explicit native apply targets captured offsets and is one undo step',
    () async {
      final controller = editor('before OLD after', 7, 10);
      final captured = QuickAskContext.fromEditor(
        controller: controller,
        sourceLabel: 'a.dart',
        isCurrent: () => true,
      );
      expect(controller.document.text, 'before OLD after');
      expect(controller.document.isDirty, isFalse);
      controller.select(0, 0);
      expect(await captured.applyReplacement!('NEW'), isTrue);
      expect(controller.document.text, 'before NEW after');
      expect(controller.document.isDirty, isTrue);
      expect(controller.document.savedText, 'before OLD after');
      expect(await captured.applyReplacement!('AGAIN'), isFalse);
      expect(controller.undo(), isTrue);
      expect(controller.document.text, 'before OLD after');
      expect(controller.undo(), isFalse);
    },
  );

  test(
    'a changed buffer stays stale even after undo restores its text',
    () async {
      final controller = editor('original', 0, 8);
      final captured = QuickAskContext.fromEditor(
        controller: controller,
        sourceLabel: 'a.dart',
        isCurrent: () => true,
      );
      controller.applyEdits([const EditorOffsetEdit(0, 0, '!')]);
      controller.undo();
      expect(await captured.applyReplacement!('changed'), isFalse);
      expect(controller.document.text, 'original');
    },
  );

  test('a closed or changed target rejects the old result', () async {
    final controller = editor('original', 0, 8);
    var current = true;
    final captured = QuickAskContext.fromEditor(
      controller: controller,
      sourceLabel: 'a.dart',
      isCurrent: () => current,
    );
    current = false;
    expect(await captured.applyReplacement!('changed'), isFalse);
    expect(controller.document.text, 'original');
  });

  test('read-only and multiple selections never expose Apply', () {
    final controller = editor('one two', 0, 3);
    expect(
      QuickAskContext.fromEditor(
        controller: controller,
        sourceLabel: 'a.dart',
        isCurrent: () => true,
        readOnly: true,
      ).applyReplacement,
      isNull,
    );
    controller.setSelections([
      const TextSelection(baseOffset: 0, extentOffset: 3),
      const TextSelection(baseOffset: 4, extentOffset: 7),
    ]);
    final captured = QuickAskContext.fromEditor(
      controller: controller,
      sourceLabel: 'a.dart',
      isCurrent: () => true,
    );
    expect(captured.selectedText, 'one');
    expect(captured.applyReplacement, isNull);
  });

  testWidgets('nested code inherits only the nearest chat model route', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var outerCaptures = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: _Target(
          'other chat',
          sessionModel: '@other/model',
          child: _Target(
            'history',
            sessionModel: '@session/chat',
            onCapture: () => outerCaptures++,
            child: _Target(
              'code',
              child: Focus(focusNode: focus, child: const SizedBox()),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    final captured = QuickAskContext.captureFocused()!;
    expect(captured.sessionModel, '@session/chat');
    expect(captured.selectedText, 'code selection');
    expect(captured.contextText, isEmpty);
    expect(captured.sourceLabel, 'code');
    expect(outerCaptures, 0);
    expect(
      captured.selectionAnchor?.call(),
      const Rect.fromLTWH(12, 34, 1, 18),
    );
    expect(captured.selectionAnchorListenable, isNotNull);
  });

  test('text and editor factories preserve an explicit session route', () {
    final text = QuickAskContext.fromText(
      text: 'code',
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
      sourceLabel: 'draft',
      sessionModel: '@session/chat',
    );
    expect(text.sessionModel, '@session/chat');
    final native = QuickAskContext.fromEditor(
      controller: editor('code', 0, 4),
      sourceLabel: 'file',
      isCurrent: () => true,
      sessionModel: '@session/chat',
    );
    expect(native.sessionModel, '@session/chat');
    expect(native.canApply, isTrue);
  });

  testWidgets('capture chooses the inner target before focus moves', (
    tester,
  ) async {
    final codeFocus = FocusNode();
    final popupFocus = FocusNode();
    addTearDown(codeFocus.dispose);
    addTearDown(popupFocus.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            _Target(
              'chat',
              child: _Target(
                'code',
                child: Focus(focusNode: codeFocus, child: const SizedBox()),
              ),
            ),
            Focus(focusNode: popupFocus, child: const SizedBox()),
          ],
        ),
      ),
    );
    codeFocus.requestFocus();
    await tester.pump();
    final captured = QuickAskContext.captureFocused();
    expect(captured?.sourceLabel, 'code');
    popupFocus.requestFocus();
    await tester.pump();
    expect(QuickAskContext.captureFocused(), isNull);
    expect(captured?.selectedText, 'code selection');
    expect(QuickAskContext.captureOf(null), isNull);
  });
}

class _Target extends StatefulWidget {
  const _Target(
    this.label, {
    required this.child,
    this.sessionModel,
    this.onCapture,
  });
  final String label;
  final String? sessionModel;
  final VoidCallback? onCapture;
  final Widget child;
  @override
  State<_Target> createState() => _TargetState();
}

class _TargetState extends State<_Target> with QuickAskTarget {
  final _geometry = ValueNotifier(0);
  @override
  void dispose() {
    _geometry.dispose();
    super.dispose();
  }

  @override
  String? get quickAskSessionModel => widget.sessionModel;
  @override
  QuickAskContext captureQuickAskContext() {
    widget.onCapture?.call();
    return QuickAskContext(
      sourceLabel: widget.label,
      selectedText: '${widget.label} selection',
      selectionAnchor: () => const Rect.fromLTWH(12, 34, 1, 18),
      selectionAnchorListenable: _geometry,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
