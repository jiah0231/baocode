import 'dart:async';

/// Sanitized failure from the test-only sandbox diagnostic monitor.
class ChromeSandboxFailure extends StateError {
  ChromeSandboxFailure._(super.message);
}

/// Test-only tripwire for a known Chrome sandbox failure diagnostic.
///
/// The absence of this diagnostic does not prove that Chrome is sandboxed.
/// Callers must keep both output streams monitored throughout the operation,
/// call [failMonitoring] on stream errors, and stop Chrome in [onViolation].
class ChromeSandboxGuard {
  ChromeSandboxGuard({this.onViolation});

  static const _marker = 'sandbox cannot access executable';
  static const _scanSize = 1024;

  /// Called synchronously, once, after failure is latched. Cleanup failures
  /// cannot replace the guard's sanitized failure.
  final void Function()? onViolation;

  final _waiters = <Completer<void>>{};
  String _stdoutTail = '';
  String _stderrTail = '';
  ChromeSandboxFailure? _failure;

  bool get failed => _failure != null;

  /// Exposes only the retained size for synthetic tests, never log contents.
  int get retainedOutputCharacters => _stdoutTail.length + _stderrTail.length;

  /// Scans decoded chunks without waiting for a newline. Stream tails stay
  /// separate so interleaved stdout/stderr cannot manufacture a diagnostic.
  void addOutput(String stream, String chunk) {
    if (stream != 'stdout' && stream != 'stderr') {
      failMonitoring();
      check();
    }
    if (failed || chunk.isEmpty) {
      return;
    }

    var tail = stream == 'stdout' ? _stdoutTail : _stderrTail;
    final retainedLimit = _marker.length - 1;
    for (var offset = 0; offset < chunk.length; offset += _scanSize) {
      final end = offset + _scanSize < chunk.length
          ? offset + _scanSize
          : chunk.length;
      final window = (tail + chunk.substring(offset, end)).toLowerCase();
      if (window.contains(_marker)) {
        _trip(
          'Chrome sandbox failure detected; refusing to continue this test.',
        );
        return;
      }
      tail = window.length <= retainedLimit
          ? window
          : window.substring(window.length - retainedLimit);
    }
    if (stream == 'stdout') {
      _stdoutTail = tail;
    } else {
      _stderrTail = tail;
    }
  }

  /// A failed output subscription cannot establish the absence of a warning.
  /// Deliberately accepts no exception/log payload, which might contain paths.
  void failMonitoring() {
    _trip('Chrome sandbox output monitoring failed; refusing to continue.');
  }

  void check() {
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
  }

  /// Rejects new work after failure and races in-flight work against failure.
  /// The operation itself is not cancellable; [onViolation] owns stopping its
  /// external resources. Late results/errors are observed but cannot win.
  Future<T> run<T>(Future<T> Function() operation) async {
    check();
    final violation = Completer<void>();
    _waiters.add(violation);
    try {
      final value = await Future.any<T>([
        Future<T>.sync(operation),
        violation.future.then<T>((_) => throw _failure!),
      ]);
      check();
      return value;
    } catch (_) {
      check();
      rethrow;
    } finally {
      _waiters.remove(violation);
    }
  }

  void _trip(String message) {
    if (failed) {
      return;
    }
    _failure = ChromeSandboxFailure._(message);
    _stdoutTail = '';
    _stderrTail = '';
    // These signals complete normally, so an idle guard never emits an
    // unhandled asynchronous error. Finished operations remove their waiter.
    for (final waiter in _waiters) {
      waiter.complete();
    }
    _waiters.clear();
    try {
      onViolation?.call();
    } catch (_) {
      // The already-latched guard failure remains authoritative.
    }
  }
}
