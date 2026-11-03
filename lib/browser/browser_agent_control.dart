import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import 'browser_bridge.dart';

/// A local, global handover to the human. This is an execution gate, not a
/// tool-advertisement switch: every agent bridge write and result uses a lease.
/// Mirror/controller requests deliberately run outside the agent zone.
class BrowserAgentControl extends ChangeNotifier {
  BrowserAgentControl._();

  static final instance = BrowserAgentControl._();
  static final Object _leaseKey = Object();
  static final recordingNonce = '$pid-${DateTime.now().microsecondsSinceEpoch}';

  bool get manualControl {
    _ensureState();
    return _manualControl;
  }
  bool _manualControl = true;
  int get epoch {
    _ensureState();
    return _epoch;
  }
  int _epoch = 0;
  Completer<void> _revoked = Completer<void>();
  final Map<String, BrowserConnection> _sessions = {};
  final Set<BrowserTab> _agentTabs = {};
  final Map<BrowserTab, Set<String>> _features = {};
  final Set<BrowserTab> _detached = {};
  Future<void>? _cleanup;
  bool _resumeRequested = false;
  String? _cleanupError;
  String? _stateError;
  String? get cleanupError => _stateError ?? _cleanupError;
  String? _statePath;
  bool get cleaningUp => _cleaningUp;
  bool _cleaningUp = false;
  Future<void> get ready => _cleanup ?? Future<void>.value();
  BrowserTab? _selected;
  BrowserConnection? _anonymousBrowser;

  static BrowserAgentLease? get currentLease =>
      Zone.current[_leaseKey] as BrowserAgentLease?;

  /// Explicit human selection only. A session's existing binding wins.
  void selectTarget(BrowserTab target) {
    _selected = target;
  }

  void bindSession(String sessionId, BrowserTab target) {
    _sessions.putIfAbsent(sessionId, () => target.browser);
  }

  /// Only for an explicit safe reset, never for a connection disappearing.
  void unbindSession(String sessionId) => _sessions.remove(sessionId);

  void takeOver() {
    _ensureState();
    if (_manualControl) return;
    _manualControl = true;
    _saveState();
    _invalidate();
    _resumeRequested = false;
    _cleanupError = null;
    // The only requests allowed here are hard-coded teardown, never a tool's
    // continuation. Acknowledged domain shutdown covers half-finished setup;
    // recorder generation tokens also reject any old script emissions.
    _cleaningUp = true;
    _cleanup = Zone.root.run(() => _cleanTabs([..._agentTabs]));
    notifyListeners();
  }

  void resume() {
    _ensureState();
    if (!_manualControl) return;
    _resumeRequested = true;
    if (_cleanupError != null) {
      _cleanupError = null;
      _cleaningUp = true;
      _cleanup = Zone.root.run(() => _cleanTabs([..._agentTabs]));
    }
    final cleanup = _cleanup;
    if (cleanup != null) {
      unawaited(cleanup.then((_) {
        if (_resumeRequested && _cleanupError == null) _resumeNow();
      }));
    } else {
      _resumeNow();
    }
  }

  void _resumeNow() {
    if (!_manualControl) return;
    // The durable guard remains paused even while this process is allowed
    // to act. A crash/restart can never reuse an earlier run's permission.
    if (!_saveState()) {
      notifyListeners();
      return;
    }
    _manualControl = false;
    _resumeRequested = false;
    _cleanup = null;
    // Resuming allows NEW calls. It never revives a previously issued lease.
    notifyListeners();
  }

  void track(BrowserConnection browser, Map<String, Object?> params) {
    if (params['tabId'] case final int tabId) {
      final tab = BrowserTab(browser, tabId);
      _agentTabs.add(tab);
      if (params['method'] case final String method) {
        (_features[tab] ??= {}).add(method);
      }
    }
  }

  /// A fresh human reconnect action, never restoration of a saved selection.
  void reconnectTab(BrowserTab tab) => _detached.remove(tab);

  bool isDetached(BrowserTab tab) => _detached.contains(tab);

  void markDetached(BrowserTab tab) {
    _detached.add(tab);
    forgetTab(tab);
  }

  void checkTab(BrowserTab tab) {
    if (_detached.contains(tab)) {
      throw const BrowserControlError(
        'Browser debugging was cancelled. Select the tab explicitly in the '
        'browser panel before reconnecting.',
      );
    }
  }

  void traceCompleted(BrowserTab tab) =>
      _features[tab]?.remove('Tracing.start');

  void forgetTab(BrowserTab tab) {
    _agentTabs.remove(tab);
    _features.remove(tab);
  }

  Future<void> _cleanTabs(List<BrowserTab> tabs) async {
    await Future.wait(tabs.map((tab) async {
      if (!tab.browser.connected || isDetached(tab)) {
        forgetTab(tab);
        return;
      }
      var clean = true;
      Future<void> disable(
        String method, [
        Map<String, Object?> params = const {},
      ]) async {
        if (isDetached(tab) || !tab.browser.connected) return;
        try {
          await tab.browser.cdp(
            tab.tabId, method, params, const Duration(seconds: 2),
          );
        } on Object catch (error) {
          if (method == 'Tracing.end' &&
              '$error'.contains('Tracing is not started')) {
            return;
          }
          if (tab.browser.connected) {
            clean = false;
            _cleanupError = 'Browser cleanup did not finish ($method). '
                'Automation stays paused. Resume retries cleanup.';
          }
        }
      }
      Future<void> finishTrace() async {
        if (isDetached(tab) || !tab.browser.connected) return;
        final complete = Completer<void>();
        final subscription = BrowserBridge.instance.events.listen((event) {
          if (identical(event.connection, tab.browser) &&
              event.tabId == tab.tabId &&
              event.message['method'] == 'Tracing.tracingComplete' &&
              !complete.isCompleted) complete.complete();
        });
        try {
          await Future.wait<void>([
            tab.browser.cdp(tab.tabId, 'Tracing.end', const {},
                const Duration(seconds: 2)).then<void>((_) {}, onError: (Object error) {
              // A previous end may still be draining. Completion is required
              // even if the command says tracing is no longer active.
              if (!'$error'.contains('Tracing is not started')) throw error;
            }),
            complete.future,
          ]).timeout(const Duration(seconds: 2));
        } on Object {
          if (tab.browser.connected && !isDetached(tab)) {
            clean = false;
            _cleanupError = 'Browser trace cleanup has not completed. '
                'Automation stays paused. Resume retries cleanup.';
          }
        } finally {
          await subscription.cancel();
        }
      }
      final features = _features[tab] ?? const <String>{};
      // Independent disables run together: at most two seconds per stage,
      // eight seconds total per tab, with all tabs cleaned concurrently.
      await Future.wait([
        if (features.contains('Fetch.enable')) disable('Fetch.disable'),
        if (features.contains('Debugger.enable')) disable('Debugger.disable'),
        if (features.contains('Tracing.start')) finishTrace(),
        if (features.contains('CSS.startRuleUsageTracking'))
          disable('CSS.disable'),
        if (features.contains('Page.setInterceptFileChooserDialog'))
          disable('Page.setInterceptFileChooserDialog', {'enabled': false}),
      ]);
      if (isDetached(tab) || !tab.browser.connected) return;
      try {
        await tab.browser.cdp(tab.tabId, 'Runtime.evaluate', {
          'expression': 'window.__baoWatch?.stop(true); '
              'window.__baoHistory?.stop(true);',
        }, const Duration(seconds: 2));
      } on Object {
        // A modal dialog can prevent evaluation. Binding removal below and
        // recorder generation checks still discard every old emission.
      }
      if (isDetached(tab) || !tab.browser.connected) return;
      await Future.wait([
        for (final name in ['__baoWatchStep', '__baoHistoryStep'])
          disable('Runtime.removeBinding', {'name': name}),
        if (features.contains('Target.setAutoAttach'))
          disable('Target.setAutoAttach', {
            'autoAttach': false,
            'waitForDebuggerOnStart': false,
            'flatten': true,
          }),
        for (final domain in ['Network', 'Log', 'Runtime', 'Page', 'Performance'])
          disable('$domain.disable'),
      ]);
      // Existing extensions swallow detach errors. Do not use its response as
      // proof of privacy cleanup: the acknowledged CDP disables above are it.
      if (isDetached(tab) || !tab.browser.connected) return;
      await Future.wait([
        tab.browser.request('detach', {'tabId': tab.tabId},
            const Duration(seconds: 2)).then<void>((_) {}, onError: (Object _) {}),
        tab.browser.request('watch', {'tabId': null},
            const Duration(seconds: 2)).then<void>((_) {}, onError: (Object _) {}),
      ]);
      if (clean) forgetTab(tab);
    }));
    _cleaningUp = false;
    notifyListeners();
  }

  void _invalidate() {
    _epoch++;
    _revoked.complete();
    _revoked = Completer<void>();
  }

  bool canObserve(int capturedEpoch) =>
      !manualControl && capturedEpoch == _epoch;

  /// Resolve once, preserving connection object identity even if a new host
  /// arrives, the same tab id exists elsewhere, or this host disconnects.
  BrowserConnection? resolveBrowser({
    String? sessionId,
    bool required = true,
  }) {
    final target = (sessionId == null ? _anonymousBrowser : _sessions[sessionId])
        ?? _selected?.browser;
    if (target != null) {
      if (!target.connected || !target.compatible) {
        throw const BrowserControlError(
          'The selected browser disconnected. Select a connected browser '
          'explicitly before continuing; another profile was not substituted.',
        );
      }
      if (sessionId == null) {
        _anonymousBrowser ??= target;
      } else {
        _sessions.putIfAbsent(sessionId, () => target);
      }
      return target;
    }
    final browsers = BrowserBridge.instance.browsers;
    if (browsers.length == 1) {
      final browser = browsers.single;
      if (sessionId == null) {
        _anonymousBrowser = browser;
      } else {
        _sessions[sessionId] = browser;
      }
      return browser;
    }
    if (!required) return null;
    if (browsers.length > 1) {
      throw const BrowserControlError(
        'Several browsers are connected. Select the intended browser tab in '
        'the browser panel before using browser tools.',
      );
    }
    throw const BrowserControlError(
      'No browser is connected. Connect the BaoCode extension first.',
    );
  }

  Future<T> runAgent<T>({
    String? sessionId,
    Future<void>? cancelled,
    bool requireBrowser = true,
    required Future<T> Function() action,
  }) async {
    _ensureState();
    currentLease?.check();
    if (_manualControl) throw const BrowserControlError.paused();
    final lease = BrowserAgentLease._(
      this,
      _epoch,
      _revoked.future,
      requireBrowser ? resolveBrowser(sessionId: sessionId) : null,
      sessionId,
    );
    if (cancelled != null) {
      unawaited(cancelled.then((_) => lease.cancel()));
    }
    // Observe an already-completed cancellation before the first write.
    await Future<void>.value();
    lease.check();
    return runZoned(
      () => lease.wait(Future<T>.sync(action)),
      zoneValues: {_leaseKey: lease},
    );
  }

  /// Background capture uses the same write/result gate as a tool call.
  /// A listener must also check the epoch stamped on its incoming event.
  Future<T> observe<T>(
    BrowserConnection browser,
    Future<T> Function() action,
  ) async {
    _ensureState();
    final existing = currentLease;
    if (existing != null) {
      existing.check(browser);
      return existing.wait(Future<T>.sync(action));
    }
    final lease = BrowserAgentLease._(
      this, _epoch, _revoked.future, browser, null,
    );
    lease.check(browser);
    return runZoned(
      () => lease.wait(Future<T>.sync(action)),
      zoneValues: {_leaseKey: lease},
    );
  }

  @visibleForTesting
  void resetForTesting() {
    _invalidate();
    _manualControl = true;
    _statePath = null;
    _stateError = null;
    _sessions.clear();
    _agentTabs.clear();
    _features.clear();
    _detached.clear();
    _cleanup = null;
    _cleaningUp = false;
    _cleanupError = null;
    _resumeRequested = false;
    _selected = null;
    _anonymousBrowser = null;
    _ensureState();
    notifyListeners();
  }

  /// Contains only the manual-control flag. No browser/page/user content.
  @visibleForTesting
  static String get stateFilePath =>
      p.join(DataDirectory.current.browserDir, 'manual-control');

  void _ensureState() {
    final path = stateFilePath;
    if (_statePath == path) return;
    if (_statePath != null) _invalidate();
    _statePath = path;
    _manualControl = true;
    _stateError = null;
    try {
      final value = File(path).readAsStringSync().trim();
      if (value == 'paused') return;
      if (value != 'resumed') {
        _stateError = 'Browser control state is unreadable. Automation stays '
            'paused until you explicitly resume.';
        return;
      }
    } on FileSystemException catch (error) {
      // An absent marker is a new installation, not an unknown read failure.
      if (error.osError?.errorCode != 2 && error.osError?.errorCode != 3) {
        _stateError = 'Browser control state could not be read. Automation '
            'stays paused until you explicitly resume.';
        return;
      }
    }
    // Every process starts paused. A legacy resumed marker never grants
    // authority in a new process; only a fresh explicit Resume does.
    _saveState();
  }

  bool _saveState() {
    final path = _statePath!;
    final pending = File('$path.$pid.pending');
    try {
      pending.parent.createSync(recursive: true);
      pending.writeAsStringSync('paused\n', flush: true);
      pending.renameSync(path);
      _stateError = null;
      return true;
    } on FileSystemException {
      _stateError = 'Browser control state could not be saved. Automation '
          'remains paused; check storage access and try Resume again.';
      try {
        if (pending.existsSync()) pending.deleteSync();
      } on FileSystemException {
        // Only our own incomplete flag file, never browser/history data.
      }
      return false;
    }
  }
}

/// Immutable authority for one call. Cancellation and takeover are permanent
/// for this lease, including its async continuations and event listeners.
class BrowserAgentLease {
  BrowserAgentLease._(
    this._control, this.epoch, this._revoked, this.browser, this.sessionId,
  );

  final String? sessionId;

  final BrowserAgentControl _control;
  final int epoch;
  final BrowserConnection? browser;
  final Future<void> _revoked;
  final Completer<void> _cancelled = Completer<void>();

  bool get valid =>
      !_cancelled.isCompleted && _control.canObserve(epoch);

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void check([BrowserConnection? connection]) {
    if (!valid) throw const BrowserControlError.paused();
    if (connection != null && !identical(connection, browser)) {
      throw const BrowserControlError(
        'This browser call is bound to another connection. Select the '
        'intended browser explicitly for a new call.',
      );
    }
    if (connection != null && !connection.connected) {
      throw const BrowserControlError('The selected browser disconnected.');
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    check();
    return runZoned(
      () => wait(Future<T>.sync(action)),
      zoneValues: {BrowserAgentControl._leaseKey: this},
    );
  }

  Future<T> wait<T>(Future<T> result) async {
    try {
      final value = await Future.any<T>([
        result,
        _revoked.then<T>((_) => throw const BrowserControlError.paused()),
        _cancelled.future.then<T>(
          (_) => throw const BrowserControlError.paused(),
        ),
      ]);
      check();
      return value;
    } on Object {
      // A late browser error can itself contain private page data.
      check();
      rethrow;
    }
  }
}

class BrowserControlError implements Exception {
  const BrowserControlError(this.message);
  const BrowserControlError.paused()
    : message = 'Browser automation was paused or cancelled. The user is in '
          'control. Resume and issue a new browser call to continue.';

  final String message;
  @override
  String toString() => message;
}
