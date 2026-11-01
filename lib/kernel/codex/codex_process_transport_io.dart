import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import 'codex_transport.dart';
import 'codex_path_setting.dart';

/// `codex app-server` as a child process, over its stdin and stdout.
class CodexProcessTransport implements CodexTransport {
  CodexProcessTransport._(this._process, {this.executable}) {
    _live.add(this);
    unawaited(registry.add(_process.pid));
    _process.stdout
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_line, onError: _undecodable, onDone: _stdoutDone);
    _process.stderr
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_stderrLine, onError: _undecodable);
    unawaited(_process.exitCode.then(_exited));
  }

  /// What both streams are read with, and not strict about it: a line that
  /// is not UTF-8 takes the replacement character, as the CLI's own errors
  /// can carry the console's code page on Windows.
  static const _decoder = Utf8Decoder(allowMalformed: true);

  /// A read error on either stream: kept as a stderr line, for the report
  /// when the process ends.
  void _undecodable(Object error) => _stderrLine('$error');

  /// A transport over [process], e.g. a stand-in process under test.
  @visibleForTesting
  factory CodexProcessTransport.forProcess(Process process) =>
      CodexProcessTransport._(process);

  /// Where the running processes are kept track of across runs.
  @visibleForTesting
  static CodexProcessRegistry registry = CodexProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('codex')),
  );

  static final Set<CodexProcessTransport> _live = {};

  /// Ends every Codex process this run started, and waits (up to
  /// [timeout] each) for them to go.
  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await Future.wait([
      for (final transport in [..._live]) transport._stop(timeout),
    ]);
    await registry.flush();
  }

  /// Ends the processes an earlier run left behind; see
  /// [ChildProcessRegistry].
  static Future<void> reapLeftovers() => registry.reaped;

  Future<void> _stop(Duration timeout) async {
    close();
    try {
      await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
  }

  /// Where the catalog's own server runs: anywhere it can, the sessions
  /// kept in `~/.codex` rather than a project's.
  static String get _home =>
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;

  static Future<CodexTransport> startCatalog() =>
      start(CodexLaunch(cwd: _home));

  static Future<CodexTransport> start(CodexLaunch launch) async {
    await registry.reaped;
    if (!Directory(launch.cwd).existsSync()) {
      throw CodexFolderGone(launch.cwd);
    }
    final environment = await ClaudeEnvironment.of();
    final executable = await locateExecutable(
      environment,
      configuredPath: CodexPathSetting.current(),
    );
    if (executable == null) {
      throw const CodexUnavailable(
        'Codex is not installed',
        detail:
            'Install it with `npm install -g @openai/codex`, then try '
            'again, or choose its executable in Settings → General → Codex.',
      );
    }
    final proxy = await NetworkProxy.instance.environment();
    try {
      final process = await Process.start(
        executable,
        const ['app-server'],
        workingDirectory: launch.cwd,
        environment: {...environment, ...proxy, ...?launch.env},
        // The login shell's environment is the whole of it; on Windows it
        // is the app's own, and the child needs the parent's beside it for
        // what `cmd.exe` itself runs on (COMSPEC, PATHEXT, …).
        includeParentEnvironment: Platform.isWindows,
        // An npm shim is a `.cmd`, which only the shell can run.
        runInShell: Platform.isWindows,
      );
      return CodexProcessTransport._(process, executable: executable);
    } on ProcessException catch (error) {
      throw CodexUnavailable(
        'Codex could not start',
        detail: '$executable\n${error.message}',
      );
    }
  }

  /// `codex` on the login shell's PATH, else where it is commonly
  /// installed; null when none is found.
  @visibleForTesting
  static Future<String?> locateExecutable(
    Map<String, String> environment, {
    String? configuredPath,
  }) async {
    if (CodexPathSetting.parse(configuredPath) case final configured?) {
      final home = environment['USERPROFILE'] ?? environment['HOME'] ?? '';
      final path = configured.startsWith('~/') || configured.startsWith(r'~\')
          ? p.normalize('$home${configured.substring(1)}')
          : configured;
      if (!p.isAbsolute(path) || !File(path).existsSync()) {
        throw CodexUnavailable(
          'The configured Codex executable was not found',
          detail:
              '$path\nChoose an existing absolute file path in Settings → '
              'General → Codex, or clear the setting to use PATH.',
        );
      }
      return path;
    }
    if (Platform.isWindows) {
      // `where` knows PATHEXT: the npm shim is `codex.cmd`.
      try {
        final result = await Process.run('where', const [
          'codex',
        ], runInShell: true);
        if (result.exitCode == 0) {
          final found = [
            for (final line in '${result.stdout}'.split('\n'))
              if (line.trim().isNotEmpty) line.trim(),
          ];
          for (final name in const ['codex.cmd', 'codex.exe', 'codex.bat']) {
            for (final path in found) {
              if (p.basename(path).toLowerCase() == name) return path;
            }
          }
          if (found.isNotEmpty) return found.first;
        }
      } on ProcessException {
        // Looked for on the PATH below.
      }
      for (final dir in (environment['PATH'] ?? '').split(';')) {
        if (dir.isEmpty) continue;
        for (final name in const ['codex.cmd', 'codex.exe', 'codex.bat']) {
          final path = p.join(dir, name);
          if (File(path).existsSync()) return path;
        }
      }
      return null;
    }
    final seen = <String>{};
    for (final dir in (environment['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final path = p.join(dir, 'codex');
      if (seen.add(path) && File(path).existsSync()) return path;
    }
    final home = environment['HOME'] ?? '';
    for (final path in [
      if (home.isNotEmpty) p.join(home, '.local', 'bin', 'codex'),
      '/usr/local/bin/codex',
      '/opt/homebrew/bin/codex',
      '/usr/bin/codex',
    ]) {
      if (seen.add(path) && File(path).existsSync()) return path;
    }
    return null;
  }

  /// Inspect the same executable local sessions use. Never install anything.
  static Future<LocalCodexStatus?> status() async {
    try {
      final environment = await ClaudeEnvironment.of();
      final executable = await locateExecutable(
        environment,
        configuredPath: CodexPathSetting.current(),
      );
      if (executable == null) return const LocalCodexMissing();
      final process = await Process.start(
        executable,
        const ['--version'],
        environment: environment,
        includeParentEnvironment: Platform.isWindows,
        runInShell: Platform.isWindows,
      );
      final output = process.stdout.transform(_decoder).join();
      final errors = process.stderr.transform(_decoder).join();
      try {
        final results = await Future.wait<Object>([
          process.exitCode,
          output,
          errors,
        ]).timeout(const Duration(seconds: 5));
        final code = results[0] as int;
        final text = (results[1] as String).trim();
        final error = (results[2] as String).trim();
        if (code != 0) {
          return LocalCodexFailed(
            '$executable\n${error.isEmpty ? text : error}',
          );
        }
        return LocalCodexFound(executable, text.isEmpty ? null : text);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        return LocalCodexFailed('$executable\nVersion check timed out.');
      }
    } on CodexUnavailable catch (error) {
      return LocalCodexFailed(error.detail ?? error.message);
    } on ProcessException catch (error) {
      return LocalCodexFailed(error.message);
    } on FileSystemException catch (error) {
      return LocalCodexFailed(error.message);
    }
  }

  final Process _process;

  /// The CLI run, to name in a report of its failing.
  final String? executable;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  /// The last lines it printed on stderr, to say why it failed.
  final List<String> _stderr = [];
  static const _stderrLines = 30;

  int? _exitCode;
  bool _stdoutClosed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) _messages.add(decoded);
    } on FormatException {
      // Not protocol (e.g. a warning printed to stdout): keep it for the
      // failure report.
      _stderrLine(line);
    }
  }

  void _stderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > _stderrLines) _stderr.removeAt(0);
  }

  void _stdoutDone() {
    _stdoutClosed = true;
    _finish();
  }

  void _exited(int code) {
    _exitCode = code;
    _live.remove(this);
    unawaited(registry.remove(_process.pid));
    _finish();
  }

  /// Ends the stream once both the output is read and the process gone,
  /// so its last messages come before the exit.
  void _finish() {
    final code = _exitCode;
    if (code == null || !_stdoutClosed || _messages.isClosed) return;
    _messages
      ..add(CodexExit.message(code, _stderr.join('\n'), executable: executable))
      ..close();
  }

  @override
  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on StateError {
      // Closed under us: the exit message follows.
    }
  }

  @override
  Future<void> get exited => _process.exitCode.then((_) {});

  @override
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.stdin.close().catchError((_) {}));
    if (Platform.isWindows) {
      unawaited(_endTree());
    } else {
      _process.kill();
    }
  }

  /// Windows ends a killed process alone, and the MCP servers it started
  /// go on without it: given a moment to end them itself, its input
  /// closed, then ended with all it started.
  Future<void> _endTree() async {
    final ended = await _process.exitCode
        .timeout(const Duration(seconds: 1))
        .then((_) => true, onError: (Object _) => false);
    if (ended) return;
    try {
      await Process.run('taskkill', ['/pid', '${_process.pid}', '/T', '/F']);
    } on ProcessException {
      _process.kill();
    }
  }
}

/// The Codex processes the app has running (`codex-processes.json`); see
/// [ChildProcessRegistry].
class CodexProcessRegistry extends ChildProcessRegistry {
  CodexProcessRegistry({
    required super.file,
    super.ownPid,
    super.lookup,
    super.signal,
  }) : super(recognizes: _isCodex);

  static bool _isCodex(String command) =>
      command.contains('codex') && command.contains('app-server');
}
