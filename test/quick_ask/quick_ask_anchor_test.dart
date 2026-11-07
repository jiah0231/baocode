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
