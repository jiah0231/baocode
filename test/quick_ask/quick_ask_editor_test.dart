import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/ide_diff_options.dart';
import 'package:baocode/ide/ide_editor.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ide/workbench/fake_files.dart';

class _Files with ReadWriteOnlyFiles implements IdeFileService {
  var text = 'modified text';
  @override
  Future<List<IdeFile>> list(String directory) async => [];
  @override
  Future<String> read(String path, {bool force = false}) async => text;
  @override
  Future<void> write(String path, String text, {String? expectedText}) async {
    this.text = text;
  }
}

Rect _nativeAnchor(WidgetTester tester, EditorSurface surface, int offset) {
  final finder = find.byWidget(surface);
  final view = tester.state(finder) as EditorSurfaceView;
  final box = tester.renderObject<RenderBox>(finder);
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    view.caretRectAt(offset)!,
  );
}

void main() {
  for (final native in [false, true]) {
    testWidgets('main editor anchors captured extent (native $native)', (
      tester,
    ) async {
      final files = _Files();
      final root = p.absolute('quick-ask-anchor-project');
      final workspace = IdeWorkspace(root, files: files);
      addTearDown(workspace.dispose);
      await workspace.open(p.join(root, 'a.txt'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IdeEditor(
              workspace: workspace,
              active: workspace.active!,
              nativeEditorEnabled: native,
              onError: (error) => fail('$error'),
              onLspStatus: (_) {},
              onPositionChanged: (_) {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      late Rect expected;
      if (native) {
        final surface = tester.widget<EditorSurface>(
          find.byType(EditorSurface),
        );
        surface.controller.select(8, 2);
        surface.focusNode!.requestFocus();
        await tester.pump();
        expected = _nativeAnchor(tester, surface, 2);
      } else {
        final field = tester.widget<EditableText>(
          find.byType(EditableText).first,
        );
        field.controller.selection = const TextSelection(
          baseOffset: 8,
          extentOffset: 2,
        );
        field.focusNode.requestFocus();
        await tester.pump();
        final render = tester
            .state<EditableTextState>(find.byType(EditableText).first)
            .renderEditable;
        expected = MatrixUtils.transformRect(
          render.getTransformTo(null),
          render.getLocalRectForCaret(const TextPosition(offset: 2)),
        );
      }
      final captured = QuickAskContext.captureFocused()!;
      expect(captured.selectionAnchor!(), expected);
      expect(captured.selectionAnchorListenable, isNotNull);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      expect(captured.selectionAnchor!(), expected);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured.selectionAnchor!(), isNull);
    });
  }

  testWidgets(
    'both diff sides capture their own text; original never applies',
    (tester) async {
      final files = _Files();
      final root = p.absolute('quick-ask-project');
      final workspace = IdeWorkspace(root, files: files);
      addTearDown(workspace.dispose);
      final options = IdeDiffOptions.instance;
      final previousLayout = options.layout;
      options.layout = IdeDiffLayout.sideBySide;
      addTearDown(() => options.layout = previousLayout);
      await workspace.openDiff(
        p.join(root, 'a.txt'),
        label: 'Working Tree',
        original: () async => 'original text',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IdeEditor(
              workspace: workspace,
              active: workspace.active!,
              onError: (error) => fail('$error'),
              onLspStatus: (_) {},
              onPositionChanged: (_) {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final surfaces = tester.widgetList<EditorSurface>(
        find.byType(EditorSurface),
      );
      final original = surfaces.singleWhere((surface) => surface.readOnly);
      original.controller.select(0, 8);
      original.focusNode!.requestFocus();
      await tester.pump();
      final readOnly = QuickAskContext.captureFocused()!;
      expect(readOnly.selectedText, 'original');
      expect(readOnly.sourceLabel, contains('(original)'));
      expect(readOnly.applyReplacement, isNull);
      final originalAnchor = _nativeAnchor(tester, original, 8);
      expect(readOnly.selectionAnchor!(), originalAnchor);

      final modified = surfaces.singleWhere((surface) => !surface.readOnly);
      modified.controller.select(0, 8);
      modified.focusNode!.requestFocus();
      await tester.pump();
      final editable = QuickAskContext.captureFocused()!;
      expect(editable.selectedText, 'modified');
      expect(editable.selectionAnchor!(), _nativeAnchor(tester, modified, 8));
      expect(readOnly.selectionAnchor!(), originalAnchor);
      expect(await editable.applyReplacement!('changed'), isTrue);
      expect(workspace.active!.text, 'changed text');
      expect(editable.selectionAnchor!(), isNull);
      expect(files.text, 'modified text');
      expect(original.controller.document.text, 'original text');
      expect(modified.controller.undo(), isTrue);
      expect(workspace.active!.text, 'modified text');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
