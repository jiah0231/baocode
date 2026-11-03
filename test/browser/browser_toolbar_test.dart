import 'package:baocode/browser/browser_toolbar.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/ide/ide_menu.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _addressKey = ValueKey('browser-panel-address');

BrowserPanelToolbar _toolbar({
  String title = 'Example',
  String url = 'https://example.com/',
  String? browserName,
  String? bindingNotice,
  bool connected = true,
  bool manualControl = false,
  ValueChanged<String>? onNavigate,
  VoidCallback? onBack,
  VoidCallback? onForward,
  VoidCallback? onReload,
  VoidCallback? onNew,
  VoidCallback? onClose,
  VoidCallback? onShow,
  VoidCallback? onTakeOver,
  VoidCallback? onResume,
  VoidCallback? onReconnectAgent,
  List<IdeMenuEntry> Function()? tabs,
  String? error,
}) => BrowserPanelToolbar(
  title: title,
  url: url,
  browserName: browserName,
  bindingNotice: bindingNotice,
  connected: connected,
  manualControl: manualControl,
  onNavigate: onNavigate ?? (_) {},
  tabs: tabs ?? () => const [],
  onBack: onBack,
  onForward: onForward,
  onReload: onReload,
  onNew: onNew,
  onClose: onClose,
  onShow: onShow,
  onTakeOver: onTakeOver,
  onResume: onResume,
  onReconnectAgent: onReconnectAgent,
  error: error,
);

Future<void> _pump(
  WidgetTester tester,
  BrowserPanelToolbar toolbar, {
  double width = 320,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                toolbar,
                TextButton(onPressed: () {}, child: const Text('Outside')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

TextField _address(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_addressKey));

Finder _action(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IdeActionButton && widget.tooltip == tooltip,
);

void main() {
  testWidgets('updates the displayed address when it is not being edited', (
    tester,
  ) async {
    await _pump(tester, _toolbar());
    expect(_address(tester).controller!.text, 'https://example.com/');
    await _pump(tester, _toolbar(url: 'https://example.com/next'));
    expect(_address(tester).controller!.text, 'https://example.com/next');
  });

  testWidgets('keeps an active draft and composition during tab URL updates', (
    tester,
  ) async {
    final navigated = <String>[];
    await _pump(tester, _toolbar(onNavigate: navigated.add));
    await tester.enterText(find.byKey(_addressKey), 'https://draft.test');
    final draft = _address(tester).controller!;
    draft.value = draft.value.copyWith(
      selection: const TextSelection.collapsed(offset: 10),
      composing: const TextRange(start: 8, end: 13),
    );
    final editing = draft.value;
    await _pump(
      tester,
      _toolbar(url: 'https://example.com/redirect', onNavigate: navigated.add),
    );
    expect(draft.value, editing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(draft.text, 'https://example.com/redirect');
    expect(_address(tester).focusNode!.hasFocus, isFalse);
    expect(navigated, isEmpty);
  });

  testWidgets('blur discards an unsubmitted draft without navigating', (
    tester,
  ) async {
    final navigated = <String>[];
    await _pump(tester, _toolbar(onNavigate: navigated.add));
    await tester.enterText(find.byKey(_addressKey), 'do not navigate here');
    expect(_address(tester).focusNode!.hasFocus, isTrue);
    await tester.tap(find.text('Outside'));
    // Cancellation is immediate, not deferred until a focus notification.
    expect(_address(tester).controller!.text, 'https://example.com/');
    await tester.pump();
    expect(_address(tester).controller!.text, 'https://example.com/');
    expect(_address(tester).focusNode!.hasFocus, isFalse);
    expect(navigated, isEmpty);
  });

  testWidgets('keyboard focus loss restores the latest URL without navigating', (
    tester,
  ) async {
    final navigated = <String>[];
    await _pump(tester, _toolbar(onNavigate: navigated.add));
    await tester.enterText(find.byKey(_addressKey), 'an unfinished draft');
    await _pump(
      tester,
      _toolbar(url: 'https://example.com/latest', onNavigate: navigated.add),
    );
    expect(_address(tester).controller!.text, 'an unfinished draft');
    _address(tester).focusNode!.unfocus();
    await tester.pump();
    expect(_address(tester).controller!.text, 'https://example.com/latest');
    expect(navigated, isEmpty);
  });

  testWidgets('Enter passes the draft to validation once and awaits the URL', (
    tester,
  ) async {
    final navigated = <String>[];
    await _pump(tester, _toolbar(onNavigate: navigated.add));
    await tester.enterText(find.byKey(_addressKey), ' example.org/path ');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(navigated, [' example.org/path ']);
    expect(_address(tester).controller!.text, ' example.org/path ');
    expect(_address(tester).focusNode!.hasFocus, isFalse);

    await _pump(
      tester,
      _toolbar(url: 'https://example.org/path', onNavigate: navigated.add),
    );
    expect(_address(tester).controller!.text, 'https://example.org/path');
    expect(navigated, hasLength(1));
  });

  testWidgets('the Go button submits the draft before blur can discard it', (
    tester,
  ) async {
    final navigated = <String>[];
    await _pump(tester, _toolbar(onNavigate: navigated.add));
    await tester.enterText(find.byKey(_addressKey), 'https://destination.test/');
    await tester.tap(_action('Go to website'));
    await tester.pump();
    expect(navigated, ['https://destination.test/']);
    expect(
      _address(tester).controller!.text,
      'https://destination.test/',
    );
  });

  testWidgets('an empty submission restores the current address', (
    tester,
  ) async {
    final navigated = <String>[];
    await _pump(tester, _toolbar(onNavigate: navigated.add));
    await tester.enterText(find.byKey(_addressKey), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(navigated, isEmpty);
    expect(_address(tester).controller!.text, 'https://example.com/');
  });

  testWidgets('exposes navigation, tab and takeover actions', (tester) async {
    final actions = <String>[];
    await _pump(
      tester,
      _toolbar(
        onBack: () => actions.add('back'),
        onForward: () => actions.add('forward'),
        onReload: () => actions.add('reload'),
        onNew: () => actions.add('new'),
        onClose: () => actions.add('close'),
        onShow: () => actions.add('show'),
        onTakeOver: () => actions.add('take over'),
      ),
    );
    for (final label in [
      'Back',
      'Forward',
      'Reload',
      'New tab',
      'Close current tab',
      'Show in Browser',
    ]) {
      await tester.tap(_action(label));
    }
    await tester.tap(find.text('Take over'));
    expect(actions, [
      'back',
      'forward',
      'reload',
      'new',
      'close',
      'show',
      'take over',
    ]);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is IdeHover &&
            widget.message ==
                'Pause all future agent browser observations and actions. '
                    'Commands already sent may finish.',
      ),
      findsOneWidget,
    );

    await _pump(
      tester,
      _toolbar(manualControl: true, onResume: () => actions.add('resume')),
    );
    expect(find.text('Take over'), findsNothing);
    await tester.tap(find.text('Resume agent'));
    expect(actions.last, 'resume');
  });

  testWidgets('loads the latest shared tabs only when the menu is opened', (
    tester,
  ) async {
    var loads = 0;
    var selected = 0;
    await _pump(
      tester,
      _toolbar(
        tabs: () {
          loads++;
          return [
            IdeMenuAction('Shared example', onSelected: () => selected++),
          ];
        },
      ),
    );
    expect(loads, 0);
    await tester.tap(_action('Shared Tabs'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.text('Shared example'), findsOneWidget);
    await tester.tap(find.text('Shared example'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('an unavailable page disables page controls and clears focus', (
    tester,
  ) async {
    var calls = 0;
    BrowserPanelToolbar toolbar(bool connected) => _toolbar(
      connected: connected,
      onNavigate: (_) => calls++,
      onBack: () => calls++,
      onForward: () => calls++,
      onReload: () => calls++,
      onNew: () => calls++,
      onClose: () => calls++,
      onShow: () => calls++,
      onTakeOver: () => calls++,
    );
    await _pump(tester, toolbar(true));
    expect(find.text('Connected to Chrome'), findsOneWidget);
    await tester.enterText(find.byKey(_addressKey), 'https://unsent.test/');
    await _pump(tester, toolbar(false));
    expect(find.text('Connected to Chrome'), findsNothing);
    expect(find.text('Selected tab unavailable'), findsOneWidget);
    expect(_address(tester).enabled, isFalse);
    expect(_address(tester).focusNode!.hasFocus, isFalse);
    expect(find.byType(IdeMenuButton), findsOneWidget);
    for (final tooltip in [
      'Back',
      'Forward',
      'Reload',
      'Close current tab',
      'Show in Browser',
      'Go to website',
    ]) {
      expect(tester.widget<IdeActionButton>(_action(tooltip)).onPressed, isNull);
    }
    expect(
      tester.widget<IdeActionButton>(_action('New tab')).onPressed,
      isNotNull,
    );
    expect(tester.widget<IdeButton>(find.byType(IdeButton)).onPressed, isNotNull);
    expect(calls, 0);
  });

  testWidgets('an unavailable page still allows picking, creating and resuming', (
    tester,
  ) async {
    final actions = <String>[];
    await _pump(
      tester,
      _toolbar(
        connected: false,
        manualControl: true,
        onNew: () => actions.add('new'),
        onResume: () => actions.add('resume'),
        tabs: () => [
          IdeMenuAction('Another tab', onSelected: () => actions.add('pick')),
        ],
      ),
    );
    await tester.tap(_action('New tab'));
    await tester.tap(find.text('Resume agent'));
    await tester.tap(_action('Shared Tabs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Another tab'));
    await tester.pumpAndSettle();
    expect(actions, ['new', 'resume', 'pick']);
  });

  testWidgets('status names the selected browser without assuming Chrome', (
    tester,
  ) async {
    await _pump(tester, _toolbar(browserName: 'Microsoft Edge'));
    expect(find.text('Connected to Microsoft Edge'), findsOneWidget);
    expect(find.text('Connected to Chrome'), findsNothing);
    await _pump(
      tester,
      _toolbar(browserName: 'Microsoft Edge', connected: false),
      locale: const Locale('zh'),
    );
    expect(find.text('所选标签页不可用'), findsOneWidget);
  });

  testWidgets('chat reconnect is explicit, localized and preserves agent pause', (
    tester,
  ) async {
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      final chinese = locale.languageCode == 'zh';
      final label = chinese ? '重新连接此会话' : 'Reconnect this chat';
      final resume = chinese ? '继续 Agent' : 'Resume agent';
      final tooltip = chinese
          ? '将此会话重新连接到所选 Chrome。旧浏览器任务作废，Agent 暂停状态不变。'
          : 'Use the selected Chrome connection for this chat. '
                'Old browser work is cancelled; agent pause stays unchanged.';
      var reconnected = 0;
      var resumed = 0;

      await _pump(tester, _toolbar(), locale: locale);
      expect(find.text(label), findsNothing);

      await _pump(
        tester,
        _toolbar(
          manualControl: true,
          onResume: () => resumed++,
          onReconnectAgent: () => reconnected++,
        ),
        locale: locale,
      );
      expect(find.text(label), findsOneWidget);
      expect(find.text(resume), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is IdeHover && widget.message == tooltip,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(label));
      await tester.pump();
      expect(reconnected, 1);
      expect(resumed, 0);
      expect(
        tester.widget<BrowserPanelToolbar>(
          find.byType(BrowserPanelToolbar),
        ).manualControl,
        isTrue,
      );
      expect(find.text(resume), findsOneWidget);

      await _pump(
        tester,
        _toolbar(manualControl: true),
        locale: locale,
      );
      expect(find.text(label), findsNothing);
      expect(find.text(resume), findsOneWidget);
    }
  });

  testWidgets('binding notices only update display and preserve callbacks', (
    tester,
  ) async {
    const noticeKey = ValueKey('browser-panel-binding-notice');
    const first = 'This panel and this chat are using different connections.';
    const second = '此面板与当前会话使用不同的连接。';
    var calls = 0;
    void navigate(String _) => calls++;
    void reconnect() => calls++;
    void resume() => calls++;

    for (final notice in [null, first, second, '', ' ']) {
      await _pump(
        tester,
        _toolbar(
          bindingNotice: notice,
          manualControl: true,
          onNavigate: navigate,
          onReconnectAgent: reconnect,
          onResume: resume,
        ),
      );
      if (notice == null || notice.trim().isEmpty) {
        expect(find.byKey(noticeKey), findsNothing);
      } else {
        final text = tester.widget<Text>(find.byKey(noticeKey));
        expect(text.data, notice);
        expect(text.maxLines, isNull);
        expect(find.text(notice == first ? second : first), findsNothing);
      }
      final toolbar = tester.widget<BrowserPanelToolbar>(
        find.byType(BrowserPanelToolbar),
      );
      expect(toolbar.onNavigate, same(navigate));
      expect(toolbar.onReconnectAgent, same(reconnect));
      expect(toolbar.onResume, same(resume));
      expect(toolbar.manualControl, isTrue);
      expect(calls, 0);
    }
  });

  testWidgets('unavailable history actions stay disabled while connected', (
    tester,
  ) async {
    await _pump(tester, _toolbar(onForward: () {}));
    expect(tester.widget<IdeActionButton>(_action('Back')).onPressed, isNull);
    expect(
      tester.widget<IdeActionButton>(_action('Forward')).onPressed,
      isNotNull,
    );
  });

  testWidgets('localized help keeps native Chrome and restart pause info usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      await _pump(
        tester,
        _toolbar(manualControl: true),
        width: 240,
        textScale: 1.5,
        locale: locale,
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(BrowserPanelToolbar)),
      )!;
      final help = find.byKey(const ValueKey('browser-panel-help'));
      expect(find.text(l10n.browserPanelPausedShort), findsOneWidget);
      expect(find.text(l10n.browserPanelChromeNotice), findsNothing);
      expect(find.text(l10n.browserPanelPausedNotice), findsNothing);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.browserPanelChromeNotice), findsOneWidget);
      expect(find.text(l10n.browserPanelPausedNotice), findsOneWidget);
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue,
      );
      await tester.ensureVisible(find.text(l10n.browserPanelPausedNotice));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(l10n.commonClose));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      tester.widget<FocusableActionDetector>(help).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(l10n.commonClose));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrow layouts wrap in both languages with readable errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const error =
        'Navigation failed. The Chrome connection is no longer available.';
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      for (final width in [240.0, 320.0, 480.0]) {
        await _pump(
          tester,
          _toolbar(
            title:
                'A very long page title that should not overflow the sidebar',
            manualControl: true,
            bindingNotice:
                'Viewing Google Chrome. Agent is bound to Google Chrome '
                '(disconnected), with access to its explicitly shared tabs.',
            onReconnectAgent: () {},
            error: error,
          ),
          locale: locale,
          width: width,
          textScale: 1.5,
        );
        expect(tester.takeException(), isNull);
        expect(find.text(error), findsOneWidget);
        expect(
          find.text(locale.languageCode == 'zh' ? 'Agent 已暂停' : 'Agent paused'),
          findsOneWidget,
        );
        expect(
          find.text(
            locale.languageCode == 'zh'
                ? '已连接 Chrome'
                : 'Connected to Chrome',
          ),
          findsOneWidget,
        );
        expect(tester.getSize(find.byType(BrowserPanelToolbar)).width, width);
        expect(
          tester.getSize(find.byType(BrowserPanelToolbar)).height,
          lessThanOrEqualTo(552),
        );
        expect(
          tester.getRect(find.text('Outside')).bottom,
          lessThanOrEqualTo(600),
        );
        final notices = tester.widget<SingleChildScrollView>(
          find.byKey(const ValueKey('browser-panel-notices')),
        );
        if (width == 240) {
          expect(notices.controller!.position.maxScrollExtent, greaterThan(0));
        }
        await tester.ensureVisible(find.text(error));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text(error)).bottom, lessThanOrEqualTo(552));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
