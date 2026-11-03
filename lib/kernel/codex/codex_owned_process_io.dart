import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Windows-only child-tree containment. The helper receives launch data over
/// its private stdin, never its command line. Child output cannot forge status:
/// the helper frames it independently from its own lifecycle messages.
class CodexOwnedProcess implements Process {
  CodexOwnedProcess._(this._helper) {
    _frames = _helper.stdout.listen(_receive,
        onError: _fail, onDone: _outputDone);
    _output.onPause = _frames.pause;
    _output.onResume = _frames.resume;
    _helper.stderr.listen(_errors.add, onError: _fail, onDone: () {
      _stderrDrained = true;
      _finish();
    });
    _helper.exitCode.then((code) {
      _helperCode = code;
      _finish();
    });
  }

  @visibleForTesting
  factory CodexOwnedProcess.forProcess(Process helper) =>
      CodexOwnedProcess._(helper);

  /// Set only by fixture tests; production resolves the installed bundle.
  @visibleForTesting
  static String? helperExecutableForTesting;

  static Future<CodexOwnedProcess> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    String? workingDirectory,
  }) async {
    final helper = helperExecutableForTesting ?? p.join(p.dirname(Platform.resolvedExecutable),
        'BaocodeCodexLauncher.exe');
    if (!File(helper).existsSync()) {
      throw ProcessException('BaocodeCodexLauncher.exe', const [],
          'The bundled Codex process launcher is missing. Reinstall BaoCode.');
    }
    final command = [quoteArgument(executable),
      ...arguments.map(quoteArgument)].join(' ');
    final header = BytesBuilder()..add(ascii.encode('BCJ1'));
    for (final field in [executable, workingDirectory ?? '', command]) {
      if (field.contains('\u0000')) {
        throw ArgumentError('Invalid NUL in launch configuration');
      }
      final bytes = utf8.encode(field);
      if (bytes.length > 1024 * 1024) {
        throw ArgumentError('Launch configuration exceeds protocol limit');
      }
      header.add((ByteData(4)..setUint32(0, bytes.length, Endian.little))
          .buffer.asUint8List());
      header.add(bytes);
    }
    final process = await Process.start(helper, const [],
        workingDirectory: workingDirectory, environment: environment);
    final owned = CodexOwnedProcess._(process);
    process.stdin.add(header.takeBytes());
    return owned;
  }

  /// Windows CRT quoting. cmd arguments used by the caller contain only fixed
  /// switches and environment placeholders; no script path enters shell text.
  static String quoteArgument(String argument) {
    if (argument.isNotEmpty && !argument.contains(RegExp(r'[\s"]'))) {
      return argument;
    }
    final out = StringBuffer('"');
    var slashes = 0;
    for (final rune in argument.runes) {
      if (rune == 92) {
        slashes++;
        continue;
      }
      if (rune == 34) {
        out.write('\\' * (slashes * 2 + 1));
      } else {
        out.write('\\' * slashes);
      }
      slashes = 0;
      out.writeCharCode(rune);
    }
    out.write('\\' * (slashes * 2));
    out.write('"');
    return out.toString();
  }

  final Process _helper;
  late final StreamSubscription<List<int>> _frames;
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  final _exit = Completer<int>();
  final List<int> _pending = [];
  int? _helperCode;
  int? rootExitCode;
  bool jobEmpty = false;
  bool launchFailed = false;
  bool _drained = false;
  bool _stderrDrained = false;
  bool _protocolFailed = false;
  String stage = 'launching';

  Map<String, Object?> get diagnostics => {
    'ownership': 'windows_job',
    'root_exited': rootExitCode != null,
    'root_exit_code': rootExitCode,
    'helper_exited': _helperCode != null,
    'job_empty': jobEmpty,
    'launcher_stage': stage,
  };

  void _receive(List<int> bytes) {
    if (_protocolFailed) return;
    _pending.addAll(bytes);
    while (_pending.length >= 5) {
      final kind = _pending[0];
      final length = ByteData.sublistView(
          Uint8List.fromList(_pending.sublist(1, 5)))
          .getUint32(0, Endian.little);
      if (length > 1024 * 1024 || kind < 1 || kind > 3) {
        _fail(StateError('Invalid launcher frame'));
        return;
      }
      if (_pending.length < length + 5) return;
      final body = _pending.sublist(5, length + 5);
      _pending.removeRange(0, length + 5);
      if (kind == 1) {
        _output.add(body);
      } else if (kind == 2) {
        _errors.add(body);
      } else {
        final status = ascii.decode(body, allowInvalid: true);
        if (status.startsWith('root_exited:')) {
          rootExitCode = int.tryParse(status.substring(12));
        } else if (status == 'job_empty') {
          jobEmpty = true;
        } else if (status.startsWith('launch_failed:')) {
          launchFailed = true;
        }
        // Native status contains fixed labels and numeric codes only.
        stage = status;
      }
    }
  }

  void _fail(Object error) {
    _protocolFailed = true;
    stage = 'launcher_protocol_failed';
    // EOF requests owned Job cleanup, without targeting a stored PID.
    unawaited(_helper.stdin.close().catchError((_) {}));
  }

  void _outputDone() {
    if (_pending.isNotEmpty) _fail(StateError('Truncated launcher frame'));
    _drained = true;
    unawaited(_output.close());
    _finish();
  }

  void _finish() {
    if (!_drained || !_stderrDrained) return;
    if (!_errors.isClosed) unawaited(_errors.close());
    if (_helperCode == null || _protocolFailed) return;
    // A crashed helper closes its job handle, but without acknowledgement we
    // cannot assert the tree is empty. Keep the writer barrier closed.
    if (!jobEmpty && !launchFailed) return;
    if (!_exit.isCompleted) _exit.complete(_helperCode!);
  }

  @override
  int get pid => _helper.pid;
  @override
  IOSink get stdin => _helper.stdin;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _errors.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    unawaited(stdin.close().catchError((_) {}));
    return false; // Only the helper's owned Job may terminate this tree.
  }
}
