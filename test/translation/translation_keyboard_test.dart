import 'package:baocode/keybindings/keybinding_service.dart';
import 'package:bao_editor/monaco/flutter/keybinding_entry.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/main.dart';
import 'package:baocode/quick_ask/quick_ask_dialog.dart';
import 'package:baocode/search/search_palette.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/translation/translation_host.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/window/window_settings.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../window/fake_window_host.dart';

void main() {
  testWidgets('single workspace never handles tool-view shortcuts', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final oldPlatform = KeybindingService.instance.debugPlatform;
    KeybindingService.instance.debugPlatform = KeybindingPlatform.windows;
    addTearDown(() => KeybindingService.instance.debugPlatform = oldPlatform);
    final oldScale = CodeFont.uiScale.value;
    addTearDown(() => CodeFont.uiScale.value = oldScale);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger = tester.binding.defaultBinaryMessenger;
    final windowCalls = <MethodCall>[];
    for (final name in [
      'baocode/window',
      'baocode/window.9',
      'baocode/translation',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name.startsWith('baocode/window')) windowCalls.add(call);
        if (call.method == 'createPanel') return 9;
        if (call.method == 'showPanel' || call.method == 'setHotkey') {
          return true;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
      );
    }
    final host = FakeWindowHost(tester.view)
      ..views[9] = FakeView(tester.view, viewId: 9);
    final workspace = Workspace.mock();
    final windows = AppWindows(
      host: host,
      workspace: workspace,
      l10n: () => englishLocalizations,
      settings: () => const WindowSettings(ideWindows: IdeWindows.mainWindow),
      hasTray: () => true,
      nextFrame: () => tester.binding.endOfFrame,
    );
    await windows.start();
    await tester.pumpWidget(
      BaoCodeApp(workspace: workspace, windows: windows),
      wrapWithView: false,
    );
    Future<void> frames() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> chord(
      LogicalKeyboardKey key, {
      bool alt = false,
      bool control = false,
      bool shift = false,
    }) async {
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      if (control) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      }
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await frames();
    }

    await frames();
    expect(windows.multi, isFalse);
    final mainFocus = FocusManager.instance.primaryFocus!;
    final translation = TranslationHost.instance;
    for (final closing in ['alt-f4', 'ctrl-w', 'ctrl-shift-w']) {
      await translation.openPanel(
        const TranslationCapture(text: 'selected', status: 'ok'),
      );
      await frames();
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<View>()
            ?.view
            .viewId,
        9,
      );
      final before = List<String>.of(host.log);
      final layout = workspace.layout;
      await chord(LogicalKeyboardKey.equal, control: true);
      await chord(LogicalKeyboardKey.keyP, control: true, shift: true);
      await chord(LogicalKeyboardKey.keyK, control: true, alt: true);
      await chord(LogicalKeyboardKey.keyN, control: true, shift: true);
      await chord(LogicalKeyboardKey.f11);
      expect(workspace.layout, layout);
      expect(
        windowCalls.where((call) => call.method == 'toggleFullScreen'),
        isEmpty,
      );
      expect(CodeFont.uiScale.value, oldScale);
      expect(find.byType(SearchPalette), findsNothing);
      expect(find.byType(QuickAskDialog), findsNothing);
      expect(host.log, before);
      expect(windows.chat.shown, isTrue);
      // Focus still belongs to the tool while its close callback clears the
      // shown flag. The global handler must reject this same key event too.
      await chord(
        closing == 'alt-f4' ? LogicalKeyboardKey.f4 : LogicalKeyboardKey.keyW,
        alt: closing == 'alt-f4',
        control: closing != 'alt-f4',
        shift: closing == 'ctrl-shift-w',
      );
      expect(translation.panelCapture, isNull, reason: closing);
      expect(windows.chat.shown, isTrue, reason: closing);
      expect(host.log, before, reason: closing);
    }
    // The ordinary workbench retains its original zoom and close shortcuts.
    mainFocus.requestFocus();
    await frames();
    await chord(LogicalKeyboardKey.equal, control: true);
    expect(CodeFont.uiScale.value, CodeFont.zoomedUiScale(oldScale, 1));
    await chord(LogicalKeyboardKey.keyW, control: true, shift: true);
    expect(windows.chat.shown, isFalse);
    expect(host.log, contains('hide 0'));
    expect(
      tester.takeException(),
      isNull,
      reason: 'shortcut handling before app teardown',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    translation.panelViewId = null;
    windows.dispose();
    expect(
      tester.takeException(),
      isNull,
      reason: 'app teardown must not notify disposing ancestors',
    );
  }, semanticsEnabled: false);
}
