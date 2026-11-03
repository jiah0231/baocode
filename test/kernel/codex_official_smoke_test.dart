import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/codex/codex_session_mcp.dart';
import 'package:baocode/kernel/codex/codex_install.dart';
import 'package:baocode/kernel/codex/codex_app_tools.dart';
import 'package:baocode/kernel/codex/codex_skills.dart';
import 'package:baocode/kernel/codex/codex_proxy_configuration.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
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
      Object? protocolFailure;
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
            .writeAsString('''
[mcp_servers.AgentDock]
command = "fixture-disabled-command"
enabled = false
env = { FIXTURE_ONLY = "kept-env" }
[mcp_servers.numeric]
url = "http://127.0.0.1:9/mcp"
enabled = false
tool_timeout_sec = 27.5
http_headers = { "X-Fixture" = "kept-header" }
''');
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
        // Reproduce a +25-created conversation's persisted model-visible
        // schema. Resume cannot replace this native dynamic tool catalogue.
        final started = await rpc.request('thread/start', {
          'cwd': project.path,
          'approvalPolicy': 'never',
          'sandbox': 'read-only',
          'dynamicTools': [{
            'type': 'function', 'name': 'session_query',
            'description': 'Legacy +25 selected conversation retrieval.',
            'inputSchema': {
              'type': 'object',
              'properties': {
                'capability': {'type': 'string'},
                'session_id': {'type': 'string'},
              },
              'required': ['capability', 'session_id'],
              'additionalProperties': false,
            },
          }],
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
        // This thread was created with the old required-capability dynamic schema
        // and without MCP config; keep its identity rather than silently fork.
        // Stop its actual writer before resuming from disk in a new process.
        await rpc.close();
        rpc = null;
        sessionQueries = SessionQueryService(read: (id) async => SessionQuerySnapshot(
          targetId: id, title: 'Selected Claude task', kernel: 'Claude Code',
          messages: const [SessionQueryMessage(
            index: 0, role: 'assistant', text: 'Smoke context port 8123.',
          )],
        ))..register();
        var smokeTurnActive = true;
        sessionQueries.grant(
          ['claude-code:smoke-target'], callerSessionId: () => threadId,
          callerCwd: project.path, callerTurnId: 'smoke-host-turn', isActive: () => smokeTurnActive,
        );
        sessionBridge = await CodexSessionMcp.start(
          cwd: project.path, sessionId: () => threadId, turnId: () => 'smoke-host-turn',
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
          'config': {
            'mcp_servers.baocode_session':
                (sessionBridge.configuration()['mcp_servers'] as Map)['baocode_session'],
          },
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
        final tool = (sessionServer['tools'] as Map).entries.singleWhere(
          (entry) => entry.key == 'session_query' ||
              (entry.value as Map)['name'] == 'session_query',
        ).value as Map;
        final newSchema = tool['inputSchema'] as Map;
        expect(newSchema['required'], ['session_id']);
        expect((newSchema['properties'] as Map).containsKey('capability'), false);
        final retrieved = await rpc.request('mcpServer/tool/call', {
          'threadId': threadId, 'server': 'baocode_session', 'tool': 'session_query',
          'arguments': {'session_id': 'claude-code:smoke-target'},
        });
        expect(retrieved['isError'], isNot(true));
        expect(jsonEncode(retrieved), contains('Smoke context port 8123.'));
        final denied = await rpc.request('mcpServer/tool/call', {
          'threadId': threadId, 'server': 'baocode_session', 'tool': 'session_query',
          'arguments': {'session_id': 'claude-code:unselected'},
        });
        expect(jsonEncode(denied), isNot(contains('Smoke context port 8123.')));
        expect(denied['isError'], true);
        smokeTurnActive = false;
        final inactive = await rpc.request('mcpServer/tool/call', {
          'threadId': threadId, 'server': 'baocode_session', 'tool': 'session_query',
          'arguments': {'session_id': 'claude-code:smoke-target'},
        });
        expect(inactive['isError'], true);
        expect(jsonEncode(inactive), isNot(contains('Smoke context port 8123.')));
        expect(rpc.sentMethods, isNot(contains('turn/start')));
        // Distinguish protocol success from later OS resource cleanup failures.
        // ignore: avoid_print
        print('Official protocol assertions complete: legacy MCP retrieval and denial passed; no model turn.');
        await rpc.close();
        rpc = null;
        await _verifyProviderRoutes(executable, environment, project, configFile);
      } on Object catch (error) {
        protocolFailure = error;
        rethrow;
      } finally {
        Object? cleanupFailure;
        StackTrace? cleanupStack;
        Future<void> clean(FutureOr<void> Function() action) async {
          try {
            await action();
          } on Object catch (error, stack) {
            cleanupFailure ??= error;
            cleanupStack ??= stack;
            // Keep the original protocol failure primary, without hiding cleanup.
            // ignore: avoid_print
            print('Official smoke cleanup failed: $error');
          }
        }
        await clean(() async { await rpc?.close(); });
        await clean(() async { await sessionBridge?.close(); });
        await clean(() { sessionQueries?.dispose(); });
        DataDirectory.current = originalDirectory;
        await clean(() => _deleteTemp(root));
        if (protocolFailure == null && cleanupFailure != null) {
          Error.throwWithStackTrace(cleanupFailure!, cleanupStack!);
        }
      }
    }, _RealHttpOverrides()),
    skip: Platform.environment['BAOCODE_CODEX_OFFICIAL_SMOKE'] != '1',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

/// Verify the exact native provider admission behavior without any model turn.
Future<void> _verifyProviderRoutes(
  String executable,
  Map<String, String> environment,
  Directory project,
  File configFile,
) async {
  const proxy = CodexProxyConfiguration(
    baseUrl: 'http://127.0.0.1:9/p/codex', token: 'isolated-fixture-only',
  );
  final before = await configFile.readAsString();
  final providerConfig = {'model_providers': {'baocode': proxy.provider}};
  _Rpc? rpc;
  Future<_Rpc> open({bool proxied = false, bool bridge = false}) async {
    final launch = CodexLaunch(cwd: project.path, proxy: proxied ? proxy : null);
    final arguments = [
      ...launch.arguments,
      if (bridge) ...[
        '-c',
        "mcp_servers.baocode_session={url='http://127.0.0.1:9/bridge',enabled=false,tool_timeout_sec=35}",
      ],
    ];
    expect(arguments.any((arg) => arg.contains(proxy.token)), false);
    final server = _Rpc(await Process.start(executable, arguments,
      workingDirectory: project.path,
      environment: {...environment, ...proxy.environment},
      includeParentEnvironment: false,
    ));
    try {
      await server.request('initialize', {
        'clientInfo': {'name': 'baocode-provider-smoke', 'version': '1.0.0'},
        'capabilities': {'experimentalApi': true},
      });
      server.notify('initialized', const {});
      return server;
    } on Object {
      await server.close();
      rethrow;
    }
  }
  Map<String, Object?> options() => {
    'cwd': project.path, 'approvalPolicy': 'never', 'sandbox': 'read-only',
    'model': 'fixture-model',
  };
  try {
    rpc = await open();
    final started = await rpc.request('thread/start', {
      ...options(), 'modelProvider': 'baocode', 'config': providerConfig,
    });
    final original = (started['thread'] as Map)['id'] as String;
    await expectLater(rpc.request('thread/resume', {
      'threadId': original, 'modelProvider': 'baocode', 'config': providerConfig,
    }), throwsA(isA<StateError>().having((e) => '$e', 'native provider check', contains('current provider is openai'))));
    await rpc.close();
    rpc = await open(proxied: true, bridge: true);
    final effective = (await rpc.request('config/read', {
      'includeLayers': false, 'cwd': project.path,
    }))['config'] as Map;
    expect(effective['model_provider'], 'baocode');
    final mcp = effective['mcp_servers'] as Map;
    expect(mcp.keys, containsAll(['AgentDock', 'numeric', 'baocode_session']));
    expect((mcp['AgentDock'] as Map)['tool_timeout_sec'], isNull);
    expect((mcp['AgentDock'] as Map)['enabled'], false);
    expect((mcp['AgentDock'] as Map)['env'], {'FIXTURE_ONLY': 'kept-env'});
    expect((mcp['numeric'] as Map)['tool_timeout_sec'], 27.5);
    expect((mcp['numeric'] as Map)['enabled'], false);
    expect((mcp['numeric'] as Map)['http_headers'], {'X-Fixture': 'kept-header'});
    final resumed = await rpc.request('thread/resume', {
      'threadId': original, 'modelProvider': 'baocode', 'config': providerConfig,
    });
    expect((resumed['thread'] as Map)['id'], original);
    await rpc.close();
    rpc = await open();
    final nativeFork = await rpc.request('thread/fork', {
      'cwd': project.path, 'approvalPolicy': 'never', 'sandbox': 'read-only',
      'threadId': original, 'deferGoalContinuation': true,
    });
    final nativeId = (nativeFork['thread'] as Map)['id'] as String;
    expect(nativeId, isNot(original));
    expect((nativeFork['thread'] as Map)['modelProvider'], 'openai');
    await rpc.close();
    rpc = await open();
    final nativeResume = await rpc.request('thread/resume', {'threadId': nativeId});
    expect((nativeResume['thread'] as Map)['id'], nativeId);
    await rpc.close();
    rpc = await open(proxied: true);
    final proxyFork = await rpc.request('thread/fork', {
      ...options(), 'threadId': nativeId, 'deferGoalContinuation': true,
      'modelProvider': 'baocode', 'config': providerConfig,
    });
    final proxyId = (proxyFork['thread'] as Map)['id'] as String;
    expect(proxyId, isNot(nativeId));
    await rpc.close();
    rpc = await open(proxied: true);
    final finalResume = await rpc.request('thread/resume', {'threadId': proxyId});
    expect((finalResume['thread'] as Map)['id'], proxyId);
    final unchanged = await rpc.request('thread/read', {'threadId': original, 'includeTurns': false});
    expect((unchanged['thread'] as Map)['modelProvider'], 'baocode');
    expect(await configFile.readAsString(), before);
    // ignore: avoid_print
    print('Native provider assertions complete: rejection, same-ID recovery, both explicit switch directions, and sparse MCP merge; no model turn.');
  } finally {
    await rpc?.close();
  }
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
  // The owned native process and its pipes have already been awaited. Windows
  // scanners/filesystem filters can retain transient handles after that point.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    try {
      if (await root.exists()) await root.delete(recursive: true);
      return;
    } on FileSystemException {
      // A persistent lock remains a failure; never silently abandon the tree.
      if (!Platform.isWindows || DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}

class _Rpc {
  _Rpc(this.process) {
    _stdout = process.stdout
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
        }, onDone: () => _stdoutDone.complete(), onError: (Object error) {
          _errors.add('stdout: $error');
        });
    _stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          _errors.add(line);
          if (_errors.length > 20) _errors.removeAt(0);
        }, onDone: () => _stderrDone.complete(), onError: (Object error) {
          _errors.add('stderr: $error');
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
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  final _stdoutDone = Completer<void>();
  final _stderrDone = Completer<void>();
  Future<void>? _closing;
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

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      try {
        await process.stdin.close().timeout(const Duration(seconds: 10));
        await process.exitCode.timeout(const Duration(seconds: 10));
      } on Object {
        // This handle is the managed native executable, not a shell/npm shim.
        // Only terminate the exact process this fixture created.
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      // exitCode alone does not guarantee the OS pipe handles were released.
      await Future.wait([_stdoutDone.future, _stderrDone.future])
          .timeout(const Duration(seconds: 10));
    } finally {
      await _stdout.cancel();
      await _stderr.cancel();
    }
  }
}
