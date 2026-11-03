import 'dart:async';

import 'package:flutter/foundation.dart';

import 'browser_bridge.dart';

/// One shared tab. The connection's name is a browser, not a profile name.
@immutable
class BrowserPanelEntry {
  const BrowserPanelEntry({
    required this.target,
    required this.title,
    required this.url,
  });

  final BrowserTab target;
  final String title;
  final String url;

  String get browserName => target.browser.browser ?? 'Browser';
}

/// The human's selected browser tab. Agent activity never changes this pick.
/// A vanished tab stays selected, unavailable, until the human picks another.
class BrowserPanelController extends ChangeNotifier {
  BrowserPanelController({BrowserBridge? bridge})
    : _bridge = bridge ?? BrowserBridge.instance {
    _bridge.addListener(_bridgeChanged);
    _events = _bridge.events.listen(_received);
    unawaited(refresh());
  }

  final BrowserBridge _bridge;
  late final StreamSubscription<BrowserEvent> _events;
  final Map<BrowserTab, BrowserPanelEntry> _tabs = {};

  // Events arriving during tabs.list win over that request's older snapshot,
  // including removals: a late list must not resurrect an unshared tab.
  final Map<BrowserTab, int> _changed = {};
  int _revision = 0;
  int _refreshGeneration = 0;
  int _generation = 0;
  bool _disposed = false;
  bool _everSelected = false;
  bool _wasConnected = false;
  BrowserTab? _selected;
  BrowserPanelEntry? _lastEntry;
  String? _error;
  static const _refreshFailure = 'Could not refresh shared tabs.';

  BrowserTab? get selected => _selected;
  BrowserPanelEntry? get selectedEntry => _lastEntry;
  List<BrowserPanelEntry> get tabs => List.unmodifiable(_tabs.values);
  bool get connected =>
      _selected != null &&
      _live(_selected!.browser) &&
      _tabs.containsKey(_selected);
  String get title => _lastEntry?.title ?? '';
  String get url => _lastEntry?.url ?? '';
  String? get error => _error;

  bool _live(BrowserConnection browser) =>
      _bridge.enabled &&
      _bridge.browsers.any((other) => identical(browser, other));

  void _publish() {
    if (_disposed) return;
    if (!_everSelected && _tabs.isNotEmpty) {
      _selected = _tabs.keys.first;
      _everSelected = true;
      _generation++;
    }
    if (_tabs[_selected] case final entry?) _lastEntry = entry;
    final available = connected;
    if (_wasConnected && !available) _generation++;
    _wasConnected = available;
    notifyListeners();
  }

  void _bridgeChanged() {
    if (_disposed) return;
    _tabs.removeWhere((tab, _) => !_live(tab.browser));
    _changed.removeWhere((tab, _) => !_live(tab.browser));
    _publish();
    unawaited(refresh());
  }

  /// Only the extension's shared tabs are requested, across live connections.
  Future<void> refresh() async {
    if (_disposed) return;
    final refresh = ++_refreshGeneration;
    final revision = _revision;
    final generation = _generation;
    final browsers = _bridge.enabled ? _bridge.browsers : <BrowserConnection>[];
    final answers = await Future.wait([
      for (final browser in browsers)
        () async {
          try {
            final result = await browser.request('tabs.list');
            return (browser, result is List ? result : const [], false);
          } on Object {
            return (browser, const [], true);
          }
        }(),
    ]);
    if (_disposed || refresh != _refreshGeneration) return;
    _tabs.removeWhere((tab, _) => !_live(tab.browser));
    for (final (browser, list, failed) in answers) {
      if (!_live(browser)) continue;
      if (failed) {
        if (_generation == generation &&
            (_selected == null || identical(_selected!.browser, browser))) {
          _error = _refreshFailure;
        }
        continue;
      }
      if (_generation == generation &&
          _error == _refreshFailure &&
          (_selected == null || identical(_selected!.browser, browser))) {
        _error = null;
      }
      final listed = <BrowserTab, BrowserPanelEntry>{};
      for (final info in list) {
        final entry = _entry(browser, info);
        if (entry != null) listed[entry.target] = entry;
      }
      _tabs.removeWhere(
        (tab, _) =>
            identical(tab.browser, browser) &&
            !listed.containsKey(tab) &&
            (_changed[tab] ?? 0) <= revision,
      );
      for (final entry in listed.values) {
        if ((_changed[entry.target] ?? 0) <= revision) {
          _tabs[entry.target] = entry;
        }
      }
    }
    _publish();
  }

  void select(BrowserTab tab) {
    if (_disposed) return;
    _generation++;
    _everSelected = true;
    _selected = tab;
    _lastEntry = _tabs[tab];
    _error = null;
    _publish();
  }

  void _received(BrowserEvent event) {
    if (_disposed || !_live(event.connection)) return;
    switch (event.event) {
      case 'tab':
        final entry = _entry(event.connection, event.message['tab']);
        if (entry == null) return;
        _changed[entry.target] = ++_revision;
        _tabs[entry.target] = entry;
      case 'closed' || 'unshared':
        final id = event.tabId;
        if (id == null) return;
        final tab = BrowserTab(event.connection, id);
        _changed[tab] = ++_revision;
        _tabs.remove(tab);
      default:
        return;
    }
    _publish();
  }

  static BrowserPanelEntry? _entry(BrowserConnection browser, Object? info) {
    if (info is! Map || info['tabId'] is! int) return null;
    return BrowserPanelEntry(
      target: BrowserTab(browser, info['tabId'] as int),
      title: info['title'] is String ? info['title'] as String : '',
      url: _displayUrl(info['url']),
    );
  }

  static String _displayUrl(Object? value) {
    if (value is! String) return '';
    try {
      final uri = Uri.parse(value);
      return uri.hasAuthority ? uri.replace(userInfo: '').toString() : value;
    } on FormatException {
      return '';
    }
  }

  bool _current(BrowserTab? tab, int generation) =>
      !_disposed && _generation == generation && _selected == tab;

  Future<void> _perform(
    Future<void> Function(BrowserTab tab, int generation) action,
  ) async {
    if (_disposed) return;
    final tab = _selected;
    final generation = ++_generation;
    if (tab == null || !connected) {
      _error = 'The selected tab is no longer shared or connected.';
      _publish();
      return;
    }
    _error = null;
    _publish();
    if (!_current(tab, generation) || !connected) return;
    try {
      await action(tab, generation);
    } on Object {
      if (!_current(tab, generation)) return;
      // Browser errors can contain the requested URL, including credentials.
      _error = 'The browser could not complete this action.';
      _publish();
    }
  }

  Future<void> navigate(String address) async {
    if (_disposed) return;
    final normalized = _navigationUrl(address);
    if (normalized == null) {
      _generation++;
      _error = 'Enter an http:// or https:// address without credentials.';
      _publish();
      return;
    }
    await _perform((tab, _) async {
      final result = await tab.browser.cdp(tab.tabId, 'Page.navigate', {
        'url': normalized,
      });
      if (result['errorText'] != null) throw StateError('Navigation failed.');
    });
  }

  static String? _navigationUrl(String input) {
    final text = input.trim();
    if (text.isEmpty ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(text) ||
        text.startsWith('//')) {
      return null;
    }
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(text);
    final web = RegExp(r'^https?://', caseSensitive: false).hasMatch(text);
    // A domain's port is not a URL scheme. Single names with ports are
    // deliberately limited to localhost to avoid interpreting javascript:123.
    final hostPort = RegExp(
      r'^(?:localhost|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+):[0-9]+(?:[/?#]|$)',
      caseSensitive: false,
    ).hasMatch(text);
    if (hasScheme && !web && !hostPort) return null;
    final address = web ? text : 'https://$text';
    final authority = address
        .substring(address.indexOf('://') + 3)
        .split(RegExp(r'[/\?#]'))
        .first;
    // Uri.parse normalizes an empty port away. Check the original authority
    // before parsing, while allowing bracketed IPv6 and nonempty ports.
    if (authority.contains('@') ||
        authority.contains('%') ||
        authority.endsWith(':')) {
      return null;
    }
    try {
      final uri = Uri.parse(address);
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          !uri.hasAuthority ||
          uri.authority.contains('@') ||
          uri.authority.contains('%') ||
          uri.authority.endsWith(':') ||
          uri.userInfo.isNotEmpty ||
          uri.host.isEmpty ||
          uri.port < 1 ||
          uri.port > 65535) {
        return null;
      }
      final host = uri.host;
      final domain = RegExp(
        r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.?$',
      );
      if (!host.contains(':') &&
          (!domain.hasMatch(host) ||
              host.length > 253 ||
              host.split('.').any((label) => label.length > 63))) {
        return null;
      }
      return uri.toString();
    } on FormatException {
      return null;
    }
  }

  Future<void> back() => _history(-1);
  Future<void> forward() => _history(1);

  Future<void> _history(int direction) => _perform((tab, generation) async {
    final history = await tab.browser.cdp(
      tab.tabId,
      'Page.getNavigationHistory',
    );
    if (!_current(tab, generation) || !connected) return;
    final entries = history['entries'];
    final index = history['currentIndex'];
    if (entries is! List || index is! int) return;
    final next = index + direction;
    if (next < 0 || next >= entries.length) return;
    final entry = entries[next];
    if (entry is! Map || entry['id'] is! int) return;
    await tab.browser.cdp(tab.tabId, 'Page.navigateToHistoryEntry', {
      'entryId': entry['id'],
    });
  });

  Future<void> reload() => _perform((tab, _) async {
    await tab.browser.cdp(tab.tabId, 'Page.reload');
  });

  Future<void> showInChrome() => _perform((tab, _) async {
    await tab.browser.request('tabs.activate', {'tabId': tab.tabId});
  });

  Future<void> closeTab() => _perform((tab, generation) async {
    await tab.browser.request('tabs.close', {'tabId': tab.tabId});
    if (!_current(tab, generation)) return;
    _changed[tab] = ++_revision;
    _tabs.remove(tab);
    _publish();
  });

  Future<void> newTab() async {
    if (_disposed) return;
    final previous = _selected;
    final generation = ++_generation;
    _everSelected = true;
    // A disappeared connection is not replaced with another Chrome profile.
    final browsers = _bridge.browsers;
    if (previous == null && browsers.length > 1) {
      _error = 'Select a shared tab to choose which browser to use.';
      _publish();
      return;
    }
    final browser = previous?.browser ?? browsers.firstOrNull;
    if (browser == null || !_live(browser)) {
      _error = 'The selected browser is no longer connected.';
      _publish();
      return;
    }
    _error = null;
    _publish();
    if (!_current(previous, generation) || !_live(browser)) return;
    final revision = _revision;
    try {
      final result = await browser.request('tabs.create', {
        'url': 'about:blank',
      });
      if (!_current(previous, generation) || !_live(browser)) return;
      final entry = _entry(browser, result);
      if (entry == null) throw StateError('No tab was returned.');
      if ((_changed[entry.target] ?? 0) > revision &&
          !_tabs.containsKey(entry.target)) {
        return;
      }
      _changed[entry.target] = ++_revision;
      _tabs[entry.target] = entry;
      select(entry.target);
    } on Object {
      if (!_current(previous, generation)) return;
      _error = 'The browser could not create a new tab.';
      _publish();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _bridge.removeListener(_bridgeChanged);
    unawaited(_events.cancel());
    super.dispose();
  }
}
