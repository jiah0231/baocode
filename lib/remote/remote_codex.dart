// Codex of remote projects: `codex app-server` run on their host, by its
// server, as the user set it up there (`~/.codex` there, its login, its
// sessions). The messages are the same lines a local process's are.

import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/files.dart' show IdeFileNotFoundException;

import '../kernel/codex/codex_process_transport.dart';
import '../kernel/codex/codex_transport.dart';
import '../models/launch_environment.dart' show ProxyEndpoint;
import '../models/model_runtime.dart';
import 'remote_location.dart';
import 'ssh_host.dart';

/// Codex where [launch]'s project is: on this machine, or its host's.
Future<CodexTransport> startCodex(CodexLaunch launch) async {
  final host = RemoteLocation.hostOf(launch.cwd);
  if (host == null) return startCodexProcess(launch);
  return RemoteCodexTransport.start(SshHosts.instance[host], launch);
}

/// A server for reading the sessions kept where [location] is: this
/// machine's, or a host's. [location] null lists this machine's only.
Future<CodexTransport> startCodexCatalogServerFor(String? location) async {
  final host = location == null ? null : RemoteLocation.hostOf(location);
  if (host == null) return startCodexCatalogServer();
  return RemoteCodexTransport.start(
    SshHosts.instance[host],
    CodexLaunch(cwd: location!),
  );
}

/// Where a Codex session on [cwd]'s project sends the requests of
/// BaoCode's own models: this machine's proxy, reached through a port of
/// the host's forwarded here for a remote project. Null where there is
/// none (the web).
Future<ProxyEndpoint?> codexProxyFor(String cwd) async =>
    remoteCodexProxy(await codexProxyEndpoint(), cwd);

/// [endpoint], this machine's, as it is to be used on [cwd]'s host: a
/// port of the host's forwarded here, or as it is for a local project.
Future<ProxyEndpoint?> remoteCodexProxy(
  ProxyEndpoint? endpoint,
  String cwd,
) async {
  if (endpoint == null) return null;
  final host = RemoteLocation.hostOf(cwd);
  if (host == null) return endpoint;
  final uri = Uri.tryParse(endpoint.baseUrl);
  if (uri == null || !uri.hasPort) return endpoint;
  final client = await SshHosts.instance[host].ready;
  final forwards = _forwards[client] ??= {};
  final forward = await (forwards[uri.port] ??= client.forward(uri.port));
  return (
    baseUrl: uri
        .replace(host: '127.0.0.1', port: forward.remotePort)
        .toString(),
    token: endpoint.token,
  );
}

/// The ports forwarded for each connection, one per port here.
final Expando<Map<int, Future<RemoteForward>>> _forwards = Expando();

/// Ends the Codex processes running on other machines; for when the app
/// quits.
Future<void> stopRemoteCodexProcesses() => RemoteCodexTransport.stopAll();

/// How many Codex processes run on other machines now.
int get runningRemoteCodex => RemoteCodexTransport.running;

/// What the user is told to run on the host when it has no Codex.
const remoteCodexInstallCommand = 'npm install -g @openai/codex';

/// Codex on a remote host, over its server: the same lines as a local
/// process's (see codex_process_transport_io.dart).
class RemoteCodexTransport implements CodexTransport {
  RemoteCodexTransport._(this._process) {
    _live.add(this);
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _line,
          onError: (Object e) => _stderrLine('$e'),
          onDone: _stdoutDone,
        );
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_stderrLine, onError: (Object e) => _stderrLine('$e'));
    unawaited(_process.exitCode.then(_exited));
  }

  /// A transport over [process], e.g. a fake under test.
  factory RemoteCodexTransport.forProcess(RemoteProcess process) =>
      RemoteCodexTransport._(process);

  /// Those running, for the quit confirmation's count and to end them.
  static final Set<RemoteCodexTransport> _live = {};

  static int get running => _live.length;

  /// Ends them all: for when the app quits.
  static Future<void> stopAll() async {
    final live = [..._live];
    for (final transport in live) {
      transport.close();
    }
    await Future.wait([
      for (final transport in live)
        transport.exited.timeout(
          const Duration(seconds: 3),
          onTimeout: () => transport._process.kill(force: true),
        ),
    ]);
  }

  static Future<CodexTransport> start(SshHost host, CodexLaunch launch) async {
    final client = await _clientOf(host);
    final cwd = RemoteLocation.pathOf(launch.cwd);
    final name = RemoteLocation.hostName(host.host);
    try {
      // Nothing starts where it is not installed: said rather than left as
      // a process that ends at once.
      final found = await client.run('sh', const [
        '-lc',
        'command -v codex',
      ], cwd: cwd);
      if (found.exitCode != 0) {
        throw CodexUnavailable(
          'Codex is not installed on $name',
          detail:
              'Install it there, in a terminal of the project:\n'
              '$remoteCodexInstallCommand',
        );
      }
      final process = await client.start(
        'codex',
        launch.arguments,
        cwd: cwd,
        environment: {...?launch.env, ...?launch.proxy?.environment},
        login: true,
      );
      return RemoteCodexTransport._(process);
    } on CodexUnavailable {
      rethrow;
    } on IdeFileNotFoundException {
      throw CodexFolderGone(cwd);
    } on RpcClosed {
      throw CodexUnavailable('The connection to $name was lost');
    } on Object catch (error) {
      throw CodexUnavailable(
        'Codex could not start on $name',
        detail: '$error',
      );
    }
  }

  final RemoteProcess _process;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final List<String> _stderr = [];
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
      _stderrLine(line);
    }
  }

  void _stderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > 30) _stderr.removeAt(0);
  }

  void _stdoutDone() {
    _stdoutClosed = true;
    _finish();
  }

  void _exited(int code) {
    _exitCode = code;
    _live.remove(this);
    if (code == RemoteProcess.lostExitCode) {
      _stderrLine('The connection to the remote host was lost.');
      _stdoutClosed = true;
    }
    _finish();
  }

  void _finish() {
    final code = _exitCode;
    if (code == null || !_stdoutClosed || _messages.isClosed) return;
    _messages
      ..add(CodexExit.message(code, _stderr.join('\n')))
      ..close();
  }

  @override
  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    _process.write(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<void> get exited => _process.exitCode.then((_) {});

  @override
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.closeStdin());
    _process.kill();
  }
}

/// The host's connection, or Codex unavailable saying why not.
Future<RemoteClient> _clientOf(SshHost host) async {
  try {
    return await host.ready;
  } on SshConnectException catch (error) {
    throw CodexUnavailable(
      'Could not connect to ${RemoteLocation.hostName(host.host)}: '
      '${error.message}',
      detail: error.detail,
    );
  } on Object catch (error) {
    throw CodexUnavailable(
      'Could not connect to ${RemoteLocation.hostName(host.host)}',
      detail: '$error',
    );
  }
}
