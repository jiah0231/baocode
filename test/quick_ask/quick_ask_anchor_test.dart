import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:baocode/ide/ide_code_editor.dart';
import 'package:baocode/ide/editor_word_wrap.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wrap-boundary anchor preserves captured upstream affinity', (
    tester,
  ) async {
    final document = EditorDocumentModel('word ' * 80);
    final controller = EditorSurfaceController(document: document);
    final focus = FocusNode();
    final oldWrap = EditorWordWrap.on.value;
    EditorWordWrap.on.value = true;
    addTearDown(() {
      EditorWordWrap.on.value = oldWrap;
      focus.dispose();
      controller.dispose();
      document.dispose();
    });
    final key = GlobalKey<IdeCodeEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 280,
              child: IdeCodeEditor(
                key: key,
                controller: controller,
                path: 'wrap-anchor.txt',
                focusNode: focus,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final view = key.currentState!.view!;
    int? boundary;
    for (var offset = 1; offset < document.text.length; offset++) {
      final upstream = view.caretRectAt(
        offset,
        affinity: TextAffinity.upstream,
      )!;
      final downstream = view.caretRectAt(
        offset,
        affinity: TextAffinity.downstream,
      )!;
      if (upstream.top < downstream.top &&
          view.textArea!.overlaps(upstream) &&
          view.textArea!.overlaps(downstream)) {
        boundary = offset;
        break;
      }
    }
    expect(
      boundary,
      isNotNull,
      reason: 'The text must have a visible soft-wrap boundary.',
    );
    final offset = boundary!;
    controller.setSelections([
      TextSelection(
        baseOffset: offset + 2,
        extentOffset: offset,
        affinity: TextAffinity.upstream,
      ),
    ]);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.value.selection.affinity, TextAffinity.upstream);
    final upstreamSource = QuickAskContext.captureFocused()!;
    final box = tester.renderObject<RenderBox>(find.byType(EditorSurface));
    Rect globalCaret(TextAffinity affinity) => MatrixUtils.transformRect(
      box.getTransformTo(null),
      view.caretRectAt(offset, affinity: affinity)!,
    );
    final upstream = globalCaret(TextAffinity.upstream);
    final downstream = globalCaret(TextAffinity.downstream);
    // At this exact logical offset, affinity chooses opposite visual sides
    // of the wrap: previous row's right edge, versus next row's left edge.
    expect(upstream.top, lessThan(downstream.top));
    expect(upstream.left, greaterThan(downstream.left));
    expect(upstreamSource.selectionAnchor!(), upstream);
    expect(upstreamSource.selectionAnchor!(), isNot(downstream));

    controller.setSelections([
      TextSelection(
        baseOffset: offset + 2,
        extentOffset: offset,
        affinity: TextAffinity.downstream,
      ),
    ]);
    await tester.pumpAndSettle();
    final downstreamSource = QuickAskContext.captureFocused()!;
    expect(
      downstreamSource.selectionAnchor!(),
      globalCaret(TextAffinity.downstream),
    );
    // Changing the live selection must not alter the earlier capture.
    expect(
      upstreamSource.selectionAnchor!(),
      globalCaret(TextAffinity.upstream),
    );
    focus.unfocus();
    await tester.pump();
    expect(
      upstreamSource.selectionAnchor!(),
      globalCaret(TextAffinity.upstream),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  for (final wrap in [false, true]) {
    testWidgets('editor anchor follows extent, focus and scroll (wrap $wrap)', (
      tester,
    ) async {
      final document = EditorDocumentModel(
        List.generate(80, (i) => 'line $i: ${'word ' * 30}').join('\n'),
      );
      final controller = EditorSurfaceController(document: document);
      final focus = FocusNode();
      final oldWrap = EditorWordWrap.on.value;
      EditorWordWrap.on.value = wrap;
      addTearDown(() {
        EditorWordWrap.on.value = oldWrap;
        focus.dispose();
        controller.dispose();
        document.dispose();
      });
      final key = GlobalKey<IdeCodeEditorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 280,
                child: IdeCodeEditor(
                  key: key,
                  controller: controller,
                  path: 'anchor.txt',
                  focusNode: focus,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.select(30, 15);
      focus.requestFocus();
      await tester.pumpAndSettle();
      final source = QuickAskContext.captureFocused()!;
      final surfaceFinder = find.byType(EditorSurface);
      final box = tester.renderObject<RenderBox>(surfaceFinder);
      Rect expected() => MatrixUtils.transformRect(
        box.getTransformTo(null),
        key.currentState!.view!.caretRectAt(15)!,
      );
      expect(source.selectionAnchor!(), expected());
      expect(source.selectionAnchorListenable, isNotNull);
      focus.unfocus();
      await tester.pump();
      expect(source.selectionAnchor!(), expected());
      var ticks = 0;
      void changed() => ticks++;
      source.selectionAnchorListenable!.addListener(changed);
      if (!wrap) {
        final beforeHorizontal = source.selectionAnchor!()!;
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(surfaceFinder),
            scrollDelta: const Offset(12, 0),
          ),
        );
        await tester.pumpAndSettle();
        expect(source.selectionAnchor!(), expected());
        expect(
          source.selectionAnchor!()!.left,
          lessThan(beforeHorizontal.left),
        );
      }
      final old = source.selectionAnchor!()!;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(surfaceFinder),
          scrollDelta: const Offset(0, 12),
        ),
      );
      await tester.pumpAndSettle();
      expect(ticks, greaterThan(0));
      final moved = source.selectionAnchor!();
      if (moved != null) {
        expect(moved, expected());
        expect(moved.top, lessThan(old.top));
      }
      source.selectionAnchorListenable!.removeListener(changed);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      expect(source.selectionAnchor!(), isNull);
    });
  }
}
