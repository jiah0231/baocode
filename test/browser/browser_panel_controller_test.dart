import 'dart:async';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_panel_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Bridge bridge;
  late _Browser chrome;
  late BrowserPanelController controller;

  setUp(() async {
    chrome = _Browser('Google Chrome', [_tab(1), _tab(2)]);
    bridge = _Bridge([chrome]);
    controller = BrowserPanelController(bridge: bridge);
    await controller.refresh();
  });

  tearDown(() async {
    controller.dispose();
    await bridge.close();
  });

  test('starts with shared tabs and labels the browser, not a profile', () {
    expect(controller.selected, BrowserTab(chrome, 1));
    expect(controller.connected, isTrue);
    expect(controller.tabs.map((entry) => entry.target.tabId), [1, 2]);
    expect(controller.tabs.first.browserName, 'Google Chrome');
    expect(chrome.calls.every((call) => call.method == 'tabs.list'), isTrue);
  });

  test('tab events keep selection and update only the matching tab', () {
    controller.select(BrowserTab(chrome, 2));
    bridge.emit(chrome, 'tab', {'tab': _tab(1, title: 'Agent tab')});
    expect(controller.selected, BrowserTab(chrome, 2));
    expect(controller.title, 'Tab 2');
    bridge.emit(chrome, 'tab', {'tab': _tab(2, title: 'Human tab')});
    expect(controller.title, 'Human tab');
  });

  test('closed and unshared tabs stay pinned without a fallback', () async {
    bridge.emit(chrome, 'unshared', {'tabId': 1});
    expect(controller.selected, BrowserTab(chrome, 1));
    expect(controller.connected, isFalse);
    expect(controller.title, 'Tab 1');
    expect(controller.tabs.single.target, BrowserTab(chrome, 2));
    chrome.calls.clear();
    await controller.navigate('example.com');
    await controller.closeTab();
    expect(chrome.calls, isEmpty);

    controller.select(BrowserTab(chrome, 2));
    bridge.emit(chrome, 'closed', {'tabId': 2});
    expect(controller.selected, BrowserTab(chrome, 2));
    expect(controller.connected, isFalse);
    expect(controller.tabs, isEmpty);
  });

  test('connection identity prevents same-ID reconnect fallback', () async {
    final other = _Browser('Google Chrome', [_tab(1, title: 'Other profile')]);
    bridge.setBrowsers([other]);
    await controller.refresh();
    expect(controller.selected, BrowserTab(chrome, 1));
    expect(controller.connected, isFalse);
    expect(controller.title, 'Tab 1');
    expect(controller.tabs.single.title, 'Other profile');
    await controller.newTab();
    expect(other.calls.where((call) => call.method == 'tabs.create'), isEmpty);

    controller.select(BrowserTab(other, 1));
    expect(controller.connected, isTrue);
    expect(controller.title, 'Other profile');
    bridge.emit(chrome, 'closed', {'tabId': 1});
    expect(controller.connected, isTrue);
  });

  test('same tab IDs in separate connections never collide', () async {
    final other = _Browser('Microsoft Edge', [_tab(1, title: 'Edge tab')]);
    bridge.setBrowsers([chrome, other]);
    await controller.refresh();
    expect(controller.tabs.length, 3);
    bridge.emit(other, 'closed', {'tabId': 1});
    expect(controller.connected, isTrue);
    expect(controller.title, 'Tab 1');
    expect(controller.tabs.length, 2);
  });

  test('normalizes safe web addresses without exposing credentials', () async {
    for (final (input, expected) in [
      ('example.com/path?q=hello', 'https://example.com/path?q=hello'),
      (' https://example.com/path ', 'https://example.com/path'),
      ('http://localhost:3000/', 'http://localhost:3000/'),
      ('localhost:3000/', 'https://localhost:3000/'),
      ('example.com:8443/path', 'https://example.com:8443/path'),
      ('https://[::1]:3000/', 'https://[::1]:3000/'),
    ]) {
      chrome.calls.clear();
      await controller.navigate(input);
      expect(controller.error, isNull, reason: input);
      expect(chrome.calls.single.method, 'Page.navigate');
      expect(chrome.calls.single.params, {'url': expected});
      expect(chrome.calls.single.tabId, 1);
    }

    for (final input in [
      '',
      'javascript:alert(1)',
      'javascript:123',
      'data:text/html,hello',
      'file:///tmp/private',
      'chrome://settings',
      'devtools://inspect',
      'about:blank',
      'http:example.com',
      'https:/example.com',
      '//example.com',
      'https:///example.com',
      'https://user:password@example.com',
      'https://@example.com',
      'https://user%40example.com@evil.example',
      'https://example.com:99999',
      'https://example.com:',
      'https://example.com:0',
      'https://exa mple.com',
      'https://example.com\\@evil.example',
      'https://exa%6dple.com',
      'https://example.com/\nsecret',
    ]) {
      chrome.calls.clear();
      await controller.navigate(input);
      expect(chrome.calls, isEmpty, reason: input);
      expect(controller.error, isNotNull, reason: input);
      expect(controller.error, isNot(contains('password')));
    }

    bridge.emit(chrome, 'tab', {
      'tab': _tab(1, url: 'https://user:password@example.com/path'),
    });
    expect(controller.url, 'https://example.com/path');
    expect(controller.selectedEntry!.url, 'https://example.com/path');
  });

  test('back and forward use the captured tab and adjacent entry', () async {
    chrome.handler = (call) => call.method == 'Page.getNavigationHistory'
        ? {
            'currentIndex': 1,
            'entries': [{'id': 10}, {'id': 20}, {'id': 30}],
          }
        : <String, Object?>{};
    chrome.calls.clear();
    await controller.back();
    expect(chrome.calls.last.method, 'Page.navigateToHistoryEntry');
    expect(chrome.calls.last.params, {'entryId': 10});
    await controller.forward();
    expect(chrome.calls.last.params, {'entryId': 30});
    expect(chrome.calls.every((call) => call.tabId == 1), isTrue);
  });

  test('history boundaries are harmless', () async {
    chrome.handler = (_) => {
      'currentIndex': 0,
      'entries': [{'id': 10}],
    };
    chrome.calls.clear();
    await controller.back();
    await controller.forward();
    expect(chrome.calls.length, 2);
    expect(
      chrome.calls.every((call) => call.method == 'Page.getNavigationHistory'),
      isTrue,
    );
  });

  test('late history cannot navigate after switching away and back', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    chrome.calls.clear();
    final back = controller.back();
    controller.select(BrowserTab(chrome, 2));
    controller.select(BrowserTab(chrome, 1));
    pending.complete({
      'currentIndex': 1,
      'entries': [{'id': 10}, {'id': 20}],
    });
    await back;
    expect(chrome.calls.single.method, 'Page.getNavigationHistory');
    expect(controller.error, isNull);
  });

  test('late history is cancelled by unsharing or a newer action', () async {
    for (final unshare in [false, true]) {
      bridge.emit(chrome, 'tab', {'tab': _tab(1)});
      final pending = Completer<Object?>();
      chrome.handler = (call) => call.method == 'Page.getNavigationHistory'
          ? pending.future
          : <String, Object?>{};
      chrome.calls.clear();
      final back = controller.back();
      if (unshare) {
        bridge.emit(chrome, 'unshared', {'tabId': 1});
      } else {
        await controller.navigate('example.com/newer');
      }
      pending.complete({
        'currentIndex': 1,
        'entries': [{'id': 10}, {'id': 20}],
      });
      await back;
      expect(
        chrome.calls.where(
          (call) => call.method == 'Page.navigateToHistoryEntry',
        ),
        isEmpty,
      );
    }
  });

  test('late action error cannot replace a newer selection error', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final reload = controller.reload();
    controller.select(BrowserTab(chrome, 2));
    await controller.navigate('file:///tmp/private');
    final currentError = controller.error;
    pending.completeError(StateError('https://user:password@example.com'));
    await reload;
    expect(controller.error, currentError);
    expect(controller.selected, BrowserTab(chrome, 2));
  });

  test('a pending list cannot resurrect an unshared or closed tab', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final refresh = controller.refresh();
    bridge.emit(chrome, 'unshared', {'tabId': 1});
    bridge.emit(chrome, 'closed', {'tabId': 2});
    pending.complete([_tab(1), _tab(2)]);
    await refresh;
    expect(controller.tabs, isEmpty);
    expect(controller.selected, BrowserTab(chrome, 1));
    expect(controller.connected, isFalse);
  });

  test('a pending list cannot overwrite a newer title or shared tab', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final refresh = controller.refresh();
    bridge.emit(chrome, 'tab', {'tab': _tab(1, title: 'New title')});
    bridge.emit(chrome, 'tab', {'tab': _tab(3)});
    pending.complete([_tab(1), _tab(2)]);
    await refresh;
    expect(controller.title, 'New title');
    expect(controller.tabs.map((entry) => entry.target.tabId), [1, 2, 3]);
  });

  test('a newer refresh wins over an older pending list', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final older = controller.refresh();
    chrome.handler = null;
    chrome.shared[0] = _tab(1, title: 'Newer list');
    await controller.refresh();
    pending.complete([_tab(1, title: 'Older list')]);
    await older;
    expect(controller.title, 'Newer list');
    expect(controller.tabs.length, 2);
  });

  test('refresh recovery clears only its own error', () async {
    chrome.handler = (_) => throw StateError('List failed.');
    await controller.refresh();
    expect(controller.error, 'Could not refresh shared tabs.');
    chrome.handler = null;
    await controller.refresh();
    expect(controller.error, isNull);

    await controller.navigate('file:///tmp/private');
    final error = controller.error;
    await controller.refresh();
    expect(controller.error, error);
  });

  test('newTab creates a blank tab on the selected connection', () async {
    chrome.handler = (call) => _tab(3, url: 'about:blank');
    chrome.calls.clear();
    await controller.newTab();
    expect(chrome.calls.single.method, 'tabs.create');
    expect(chrome.calls.single.params, {'url': 'about:blank'});
    expect(controller.selected, BrowserTab(chrome, 3));
    expect(controller.connected, isTrue);
    expect(controller.url, 'about:blank');
  });

  test('newTab can recover a sole browser with no shared tabs', () async {
    controller.dispose();
    chrome.shared.clear();
    controller = BrowserPanelController(bridge: bridge);
    await controller.refresh();
    expect(controller.selected, isNull);
    chrome.handler = (call) => _tab(3, url: 'about:blank');
    await controller.newTab();
    expect(controller.selected, BrowserTab(chrome, 3));
    expect(controller.connected, isTrue);
  });

  test('newTab cannot guess a connection when none is selected', () async {
    controller.dispose();
    chrome.shared.clear();
    final other = _Browser('Google Chrome', []);
    bridge.setBrowsers([chrome, other]);
    controller = BrowserPanelController(bridge: bridge);
    await controller.refresh();
    chrome.calls.clear();
    other.calls.clear();
    await controller.newTab();
    expect(controller.selected, isNull);
    expect(controller.error, contains('Select a shared tab'));
    expect(chrome.calls, isEmpty);
    expect(other.calls, isEmpty);
  });

  test('newTab cannot resurrect a tab closed before its response', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final create = controller.newTab();
    bridge.emit(chrome, 'tab', {'tab': _tab(3)});
    bridge.emit(chrome, 'closed', {'tabId': 3});
    pending.complete(_tab(3));
    await create;
    expect(controller.selected, BrowserTab(chrome, 1));
    expect(controller.tabs.any((entry) => entry.target.tabId == 3), isFalse);
  });

  test('late newTab and close results preserve newer selection', () async {
    var pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final create = controller.newTab();
    controller.select(BrowserTab(chrome, 2));
    pending.complete(_tab(3, url: 'about:blank'));
    await create;
    expect(controller.selected, BrowserTab(chrome, 2));

    pending = Completer<Object?>();
    final close = controller.closeTab();
    controller.select(BrowserTab(chrome, 1));
    pending.complete(null);
    await close;
    expect(controller.selected, BrowserTab(chrome, 1));
    expect(controller.connected, isTrue);
  });

  test('close and show use only the selected shared tab', () async {
    chrome.calls.clear();
    controller.select(BrowserTab(chrome, 2));
    await controller.showInChrome();
    expect(chrome.calls.single.method, 'tabs.activate');
    expect(chrome.calls.single.params, {'tabId': 2});
    await controller.closeTab();
    expect(chrome.calls.last.method, 'tabs.close');
    expect(chrome.calls.last.params, {'tabId': 2});
    expect(controller.selected, BrowserTab(chrome, 2));
    expect(controller.connected, isFalse);
    expect(controller.tabs.single.target, BrowserTab(chrome, 1));
  });

  test('disposal ignores a late refresh and does not notify', () async {
    final pending = Completer<Object?>();
    chrome.handler = (_) => pending.future;
    final refresh = controller.refresh();
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.dispose();
    pending.complete([_tab(3)]);
    await refresh;
    expect(notifications, 0);
    // Give tearDown a separate live controller, rather than disposing twice.
    chrome.handler = null;
    controller = BrowserPanelController(bridge: bridge);
    await controller.refresh();
  });
}

Map<String, Object?> _tab(int id, {String? title, String? url}) => {
  'tabId': id,
  'title': title ?? 'Tab $id',
  'url': url ?? 'https://example.com/$id',
};

class _Bridge extends ChangeNotifier implements BrowserBridge {
  _Bridge(this._browsers);

  List<BrowserConnection> _browsers;
  final _events = StreamController<BrowserEvent>.broadcast(sync: true);

  @override
  List<BrowserConnection> get browsers => List.of(_browsers);

  @override
  bool get enabled => true;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  void setBrowsers(List<BrowserConnection> browsers) {
    _browsers = browsers;
    notifyListeners();
  }

  void emit(_Browser browser, String event, Map<String, Object?> message) =>
      _events.add(BrowserEvent(browser, event, message));

  Future<void> close() async {
    await _events.close();
    dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Call {
  const _Call(this.method, this.params, [this.tabId]);

  final String method;
  final Map<String, Object?> params;
  final int? tabId;
}

class _Browser implements BrowserConnection {
  _Browser(this.browser, this.shared);

  @override
  String? browser;
  final List<Map<String, Object?>> shared;
  final calls = <_Call>[];
  FutureOr<Object?> Function(_Call)? handler;

  @override
  Future<Object?> request(
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final call = _Call(method, params);
    calls.add(call);
    return handler != null
        ? await handler!(call)
        : method == 'tabs.list'
        ? shared
        : null;
  }

  @override
  Future<Map<String, Object?>> cdp(
    int tabId,
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
    String? sessionId,
  ]) async {
    final call = _Call(method, params, tabId);
    calls.add(call);
    final result = await handler?.call(call);
    return (result as Map?)?.cast<String, Object?>() ?? {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
