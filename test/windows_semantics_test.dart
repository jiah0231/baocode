import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/main.dart';
import 'package:baocode/window/app_window_semantics.dart';
import 'package:baocode/platform/app_platform.dart';
import 'package:baocode/workspace/workspace.dart';

void main() {
  // Windows' engine turns semantics on at another app's question for the
  // view's accessibility, and its bridge crashes on the tree as it changes
  // (BaoCode 1.9.4, at every start on some machines): there, the app gives
  // it nothing under the root.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BaoCodeApp(workspace: Workspace()));
    await tester.pump();
    expect(find.text('Open a project folder'), findsOneWidget);
  }

  testWidgets('on Windows, no semantics under the root', (tester) async {
    // As on Windows itself: a test targeting it from another host keeps them.
    BaoCodeApp.debugWithoutSemantics = true;
    addTearDown(() => BaoCodeApp.debugWithoutSemantics = null);
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);
    expect(find.bySemanticsLabel('Open a project folder'), findsNothing);
    final root = tester
        .binding
        .renderViews
        .single
        .owner!
        .semanticsOwner!
        .rootSemanticsNode;
    expect(root?.childrenCount ?? 0, 0);
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows defaults follow the actual host', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);
    expect(
      find.bySemanticsLabel('Open a project folder'),
      AppPlatform.isWindowsHost ? findsNothing : findsOneWidget,
    );
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('only the translation tool view keeps semantics when excluded', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            AppWindowSemantics(
              exclude: true,
              child: Semantics(
                label: 'Workspace history',
                child: const SizedBox(width: 100, height: 20),
              ),
            ),
            AppWindowSemantics(
              exclude: true,
              translation: true,
              child: Semantics(
                label: 'Fresh translation source',
                child: const SizedBox(width: 100, height: 20),
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Workspace history'), findsNothing);
    expect(find.bySemanticsLabel('Fresh translation source'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('elsewhere, the app\'s semantics as they are', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);
    expect(find.bySemanticsLabel('Open a project folder'), findsOneWidget);
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
