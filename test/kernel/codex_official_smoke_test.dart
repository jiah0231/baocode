import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/codex/codex_session_mcp.dart';
import 'package:baocode/kernel/codex/codex_install.dart';
import 'package:baocode/kernel/codex/codex_app_tools.dart';
import 'package:baocode/kernel/codex/codex_skills.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Opt-in CI integration check. It installs only the verified official package
/// in a temporary directory; there is no login, model turn, or API credential.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'official managed Codex package and app-server protocol smoke',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final root = await Directory.systemTemp.createTemp(
        'baocode-official-smoke-',
      );
      final originalDirectory = DataDirectory.current;
      DataDirectory.current = DataDirectory(root.path);
      _Rpc? rpc;
      CodexSessionMcp? sessionBridge;
      SessionQueryService? sessionQueries;
      try {
        final installer = createCodexInstaller();
        expect(installer.supported, isTrue);
        final release = await installer.latest();
        // ignore: avoid_print
        print('Official Codex ${release.version} ${release.target}');
        final executable = await installer.install(release, (message) {
          // Operational progress only: the process environment is never printed.
          // ignore: avoid_print
          print(message);
        });
        expect(await File(executable).exists(), isTrue);
        final home = await Directory(p.join(root.path, 'isolated-home'))
            .create();
        final codexHome = await Directory(p.join(home.path, '.codex')).create();
        final configFile = await File(p.join(codexHome.path, 'config.toml'))
            .writeAsString('');
        final skillDirectory = await Directory(
          p.join(codexHome.path, 'skills', 'baocode-smoke'),
        ).create(recursive: true);
        final skillFile = await File(p.join(skillDirectory.path, 'SKILL.md'))
            .writeAsString(
              '---\nname: baocode-smoke\ndescription: Isolated protocol smoke fixture.\n---\nDo not execute anything.\n',
            );
        final project = await Directory(p.join(root.path, 'project')).create();
        // Deliberately do not copy API keys, tokens, CLI config overrides, or a
        // user's home. Only OS process essentials cross into the test process.
        const allowed = {
          'path',
          'systemroot',
          'windir',
          'comspec',
          'pathext',
          'processor_architecture',
          'processor_architew6432',
          'number_of_processors',
        };
        final environment = <String, String>{
          for (final entry in Platform.environment.entries)
            if (allowed.contains(entry.key.toLowerCase()))
              entry.key: entry.value,
          'HOME': home.path,
          'USERPROFILE': home.path,
          'LOCALAPPDATA': home.path,
          'APPDATA': home.path,
          'TEMP': root.path,
          'TMP': root.path,
          'CODEX_HOME': codexHome.path,
        };
        rpc = _Rpc(
          await Process.start(
            executable,
            const ['app-server'],
            workingDirectory: project.path,
            environment: environment,
            includeParentEnvironment: false,
          ),
        );
        final initialized = await rpc.request('initialize', {
          'clientInfo': {'name': 'baocode-smoke', 'version': '1.0.0'},
          'capabilities': {'experimentalApi': true},
        });
        expect(initialized, isA<Map<String, dynamic>>());
        // ignore: avoid_print
        print('Official app-server userAgent: ${initialized['userAgent']}');
        expect(
          CodexAppTools.supportsRestrictedBots(initialized['userAgent']),
          isTrue,
          reason:
              'Official CLI must match the reviewed restricted Bots contract',
        );
        rpc.notify('initialized', const {});
        final config = await rpc.request('config/read', {
          'includeLayers': true,
          'cwd': project.path,
        });
        expect(config, contains('config'));
        final userLayers = (config['layers'] as List).where((layer) {
          if (layer is! Map || layer['name'] is! Map) return false;
          final name = layer['name'] as Map;
          return name['type'] == 'user' && name['profile'] == null;
        }).toList();
        expect(userLayers, hasLength(1));
        final userConfigPath = (userLayers.single['name'] as Map)['file'];
        expect(userConfigPath, isA<String>());
        await _expectSameFile(userConfigPath as String, configFile.path);
        final restricted = await rpc.request('thread/start', {
          'cwd': project.path,
          'approvalPolicy': 'never',
          'sandbox': 'read-only',
          'config': CodexAppTools.restrictedConfig(
            (config['config'] as Map).cast<String, Object?>(),
          ),
          'dynamicTools': await CodexAppTools(project.path).specs(),
        });
        expect((restricted['thread'] as Map)['id'], isNotEmpty);
        final skills = await rpc.request('skills/list', {
          'cwds': [project.path],
          'forceReload': true,
        });
        expect(skills, contains('data'));
        for (final entry in skills['data'] as List) {
          // ignore: avoid_print
          print(
            'Skills cwd: ${(entry as Map)['cwd']}; fixture cwd: ${project.path}',
          );
        }
        expect(
          CodexSkill.fromResponse(
            skills,
            cwd: project.path,
            paths: p.context,
          ).map((skill) => skill.name),
          contains('baocode-smoke'),
          reason: 'Production skill parser must accept the native server cwd',
        );
        Map skillFrom(Map<String, dynamic> response) => [
          for (final group in response['data'] as List)
            for (final skill in (group as Map)['skills'] as List)
              if ((skill as Map)['name'] == 'baocode-smoke') skill,
        ].single;
        final discoveredSkill = skillFrom(skills);
        await _expectSameFile(
          discoveredSkill['path'] as String,
          skillFile.path,
        );
        expect(discoveredSkill['enabled'], isTrue);
        await rpc.request('skills/config/write', {
          'path': discoveredSkill['path'],
          'enabled': false,
        });
        final disabledSkills = await rpc.request('skills/list', {
          'cwds': [project.path],
          'forceReload': true,
        });
        expect(skillFrom(disabledSkills)['enabled'], isFalse);
        // Register only an inert local agent config, never a command or hook.
        final agentFile = await File(p.join(codexHome.path, 'smoke-agent.toml'))
            .writeAsString(
              'developer_instructions = "Do not execute anything."\n',
            );
        const agentName = 'baocode_smoke';
        final agentKey = 'agents.${jsonEncode(agentName)}';
        for (final edit in <(String, Object)>[
          ('model_verbosity', 'low'),
          (
            agentKey,
            {
              'description': 'Isolated protocol smoke fixture',
              'config_file': agentFile.path,
            },
          ),
          ('$agentKey.description', 'Updated isolated protocol smoke fixture'),
        ]) {
          await rpc.request('config/value/write', {
            'keyPath': edit.$1,
            'value': edit.$2,
            'mergeStrategy': 'upsert',
            'filePath': configFile.path,
          });
        }
        final written = await rpc.request('config/read', {
          'includeLayers': true,
          'cwd': project.path,
        });
        final effective = written['config'] as Map;
        expect(effective['model_verbosity'], 'low');
        final registeredAgent = (effective['agents'] as Map)[agentName] as Map;
        await _expectSameFile(
          registeredAgent['config_file'] as String,
          agentFile.path,
        );
        expect(
          registeredAgent['description'],
          'Updated isolated protocol smoke fixture',
        );
        final started = await rpc.request('thread/start', {
          'cwd': project.path,
          'approvalPolicy': 'never',
          'sandbox': 'read-only',
        });
        final thread = started['thread'] as Map;
        final threadId = thread['id'] as String;
        expect(threadId, isNotEmpty);
        // No turn/start: this fixture must never contact a model or incur usage.
        final goal = await rpc.request('thread/goal/set', {
          'threadId': threadId,
          'origin': 'user',
          'objective': 'BaoCode protocol smoke only; do not execute',
          'status': 'paused',
        });
        expect((goal['goal'] as Map)['status'], 'paused');
        final readGoal = await rpc.request('thread/goal/get', {
          'threadId': threadId,
        });
        expect((readGoal['goal'] as Map)['status'], 'paused');
        await rpc.request('thread/goal/clear', {
          'threadId': threadId,
          'origin': 'user',
        });
        final cleared = await rpc.request('thread/goal/get', {
          'threadId': threadId,
        });
        expect(cleared['goal'], isNull);
        // This thread was created without any dynamic tools or MCP config.
        // Stop its actual writer before resuming from disk in a new process.
        await rpc.close();
        rpc = null;
        sessionQueries = SessionQueryService(read: (id) async => SessionQuerySnapshot(
          targetId: id, title: 'Selected Claude task', kernel: 'Claude Code',
          messages: const [SessionQueryMessage(
            index: 0, role: 'assistant', text: 'Smoke context port 8123.',
          )],
        ))..register();
        final capability = sessionQueries.grant(
          ['claude-code:smoke-target'], callerSessionId: () => threadId,
          callerCwd: project.path,
        );
        sessionBridge = await CodexSessionMcp.start(
          cwd: project.path, sessionId: () => threadId,
        );
        rpc = _Rpc(await Process.start(
          executable, const ['app-server'], workingDirectory: project.path,
          environment: environment, includeParentEnvironment: false,
        ));
        await rpc.request('initialize', {
          'clientInfo': {'name': 'baocode-smoke', 'version': '1.0.0'},
          'capabilities': {'experimentalApi': true},
        });
        rpc.notify('initialized', const {});
        final resumed = await rpc.request('thread/resume', {
          'threadId': threadId, 'cwd': project.path,
          'approvalPolicy': 'never', 'sandbox': 'read-only',
          'config': sessionBridge.configuration(),
        });
        expect((resumed['thread'] as Map)['id'], threadId);
        final discoveryDeadline = DateTime.now().add(const Duration(seconds: 15));
        Map? sessionServer;
        bool discovered(Map server) => (server['tools'] as Map? ?? {}).entries.any(
          (entry) => entry.key == 'session_query' ||
              (entry.value is Map && (entry.value as Map)['name'] == 'session_query'),
        );
        while (true) {
          final inventory = await rpc.request('mcpServerStatus/list', {
            'threadId': threadId, 'serverName': 'baocode_session',
          });
          sessionServer = (inventory['data'] as List).cast<Map>()
              .where((entry) => entry['name'] == 'baocode_session').firstOrNull;
          if (sessionServer != null && discovered(sessionServer)) break;
          if (sessionServer?['runtimeStatus'] == 'failed' ||
              DateTime.now().isAfter(discoveryDeadline)) {
            fail('Legacy session MCP discovery failed: '
                '${sessionServer?['runtimeStatus']}; ${sessionServer?['toolsError']}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final retrieved = await rpc.request('mcpServer/tool/call', {
          'threadId': threadId, 'server': 'baocode_session', 'tool': 'session_query',
          'arguments': {'capability': capability, 'session_id': 'claude-code:smoke-target'},
        });
        expect(retrieved['isError'], isNot(true));
        expect(jsonEncode(retrieved), contains('Smoke context port 8123.'));
        final denied = await rpc.request('mcpServer/tool/call', {
          'threadId': threadId, 'server': 'baocode_session', 'tool': 'session_query',
          'arguments': {'capability': capability, 'session_id': 'claude-code:unselected'},
        });
        expect(jsonEncode(denied), isNot(contains('Smoke context port 8123.')));
        expect(denied['isError'], true);
        expect(rpc.sentMethods, isNot(contains('turn/start')));
      } finally {
        try {
          await rpc?.close();
          await sessionBridge?.close();
          sessionQueries?.dispose();
        } finally {
          DataDirectory.current = originalDirectory;
          await _deleteTemp(root);
        }
      }
    }, _RealHttpOverrides()),
    skip: Platform.environment['BAOCODE_CODEX_OFFICIAL_SMOKE'] != '1',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

// The opt-in integration test must use real HTTPS rather than Flutter's test
// client, which responds 400 to every request. Base HttpOverrides creates the
// actual Dart client without calling the factory recursively. This is scoped
// to the test's zone; global test overrides are never modified. The production
// package source still enforces its official HTTPS host/redirect allowlist.
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      const officialHosts = {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      };
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !officialHosts.contains(uri.host) ||
          proxyHost != null ||
          proxyPort != null) {
        throw StateError('Official smoke blocked connection to $uri');
      }
      // A custom connectionFactory owns TLS too (HttpClient does not
      // upgrade its socket). Keep certificate verification enabled.
      return SecureSocket.startConnect(uri.host, uri.port, context: context);
    };
    return client;
  }
}

Future<void> _expectSameFile(String actual, String expected) async {
  // Codex's Rust canonicalization can return a Windows verbatim path while
  // Dart's temp directory uses a normal drive path (or different casing).
  // Compare OS file identity, not just path spelling, without accepting an
  // arbitrary file elsewhere in the isolated tree.
  final diagnostic = 'Codex path: $actual; fixture path: $expected';
  // ignore: avoid_print
  print(diagnostic);
  expect(
    await FileSystemEntity.identical(actual, expected),
    isTrue,
    reason: diagnostic,
  );
}

Future<void> _deleteTemp(Directory root) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await root.delete(recursive: true);
      return;
    } on FileSystemException {
      // Windows may briefly retain file handles after app-server exits. A
      // persistent failure must still fail CI, not leave credentials or files.
      if (!Platform.isWindows || attempt >= 9) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

class _Rpc {
  _Rpc(this.process) {
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final message = jsonDecode(line);
            if (message is! Map) return;
            final id = message['id'];
            if (id is! int) return;
            final pending = _pending.remove(id);
            if (pending == null) return;
            if (message['error'] != null) {
              pending.completeError(
                StateError('Codex protocol error: ${message['error']}'),
              );
            } else {
              pending.complete(
                Map<String, dynamic>.from(message['result'] as Map),
              );
            }
          } on Object catch (error) {
            for (final pending in _pending.values) {
              pending.completeError(error);
            }
            _pending.clear();
          }
        });
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          _errors.add(line);
          if (_errors.length > 20) _errors.removeAt(0);
        });
    process.exitCode.then((code) {
      for (final pending in _pending.values) {
        pending.completeError(
          StateError('Codex exited $code: ${_errors.join('\n')}'),
        );
      }
      _pending.clear();
    });
  }
  final Process process;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _errors = <String>[];
  final sentMethods = <String>[];
  int _id = 0;
  void notify(String method, Map<String, Object?> params) =>
      process.stdin.writeln(jsonEncode({'method': method, 'params': params}));
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params,
  ) async {
    if (method == 'turn/start') {
      throw StateError('Model turns are forbidden in the official smoke test');
    }
    sentMethods.add(method);
    final id = ++_id;
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    try {
      return await result.future.timeout(const Duration(seconds: 60));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
}
