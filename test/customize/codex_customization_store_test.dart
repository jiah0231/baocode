import 'dart:async';

import 'package:baocode/customize/codex_customization_store.dart';
import 'package:baocode/customize/codex_prompts.dart';
import 'package:baocode/customize/customization_disk.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class MemoryDisk implements CustomizationDisk {
  final data = <String, String>{};
  @override
  bool get isLocal => false;
  @override
  p.Context get paths => p.Context(style: p.Style.posix);
  @override
  Future<String> configDir() async =>
      throw StateError('Must not use Claude home');
  @override
  Future<String?> homeDir() async => '/home/test';
  @override
  Future<String?> read(String path) async => data[path];
  @override
  Future<void> write(String path, String text) async {
    data[path] = text;
  }

  @override
  Future<void> delete(String path) async {
    data.removeWhere((key, _) => key == path || key.startsWith('$path/'));
  }

  @override
  Future<bool?> isDirectory(String path) async => data.containsKey(path)
      ? false
      : data.keys.any((key) => key.startsWith('$path/'))
      ? true
      : null;
  @override
  Future<List<({String path, bool directory})>> children(
    String directory,
  ) async => [
    for (final path in data.keys)
      if (paths.dirname(path) == directory) (path: path, directory: false),
  ];
}

void main() {
  test('native commands and skills take precedence over prompt names', () {
    const prompts = [
      CodexPrompt('goal', '', 'wrong goal'),
      CodexPrompt('skill', '', 'wrong skill'),
      CodexPrompt('ship', '', 'ship'),
    ];
    final available = CodexPrompt.available(prompts, {
      'review',
      'init',
      'diff',
      'goal',
      'skill',
    });
    expect(available.map((p) => p.name), ['ship']);
    expect(
      CodexPrompt.expandInput('/goal do work', available),
      '/goal do work',
    );
    expect(CodexPrompt.expandInput('/skill', available), '/skill');
  });
  late MemoryDisk disk;
  late CodexCustomizationStore store;
  late Map<String, Object?> config;
  late List<(String, Map<String, Object?>)> calls;
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
  ) async {
    calls.add((method, params));
    return switch (method) {
      'config/read' => {
        'config': config,
        'layers': [
          {
            'name': {'type': 'user', 'file': '/custom/codex/config.toml'},
            'version': 'v1',
            'config': config,
          },
        ],
      },
      'skills/list' => {
        'data': [
          {
            'cwd': '/project',
            'skills': [
              {
                'name': 'check',
                'path': '/project/.agents/skills/check/SKILL.md',
                'scope': 'repo',
                'enabled': false,
              },
            ],
          },
        ],
      },
      'mcpServerStatus/list' => {
        'data': [
          {
            'name': 'files',
            'tools': {'read': {}, 'write': {}},
          },
        ],
      },
      'skills/config/write' || 'config/value/write' => {},
      _ => throw StateError('Unexpected method $method'),
    };
  }

  setUp(() {
    disk = MemoryDisk();
    calls = [];
    config = {};
    store = CodexCustomizationStore(
      disk: disk,
      request: request,
      location: 'ssh://test/',
    );
  });
  test(
    'uses reported CODEX_HOME and remote project paths, never Claude home',
    () async {
      final rules = await store.list(
        CustomizationKind.rules,
        project: '/project',
      );
      expect(rules.map((i) => i.path), [
        '/custom/codex/AGENTS.md',
        '/project/AGENTS.md',
      ]);
      expect(
        await store.create(
          CustomizationKind.commands,
          CustomizationScope.user,
          'ship',
        ),
        '/custom/codex/prompts/ship.md',
      );
      expect(
        await store.create(
          CustomizationKind.skills,
          CustomizationScope.project,
          'check',
          project: '/project',
        ),
        '/project/.agents/skills/check/SKILL.md',
      );
      expect(disk.data.keys.any((key) => key.contains('.claude')), false);
    },
  );
  test(
    'late list responses cannot replace newer row toggle metadata',
    () async {
      final delayedA = Completer<Map<String, Object?>>();
      var firstA = true;
      final observed = <(String, Map<String, Object?>)>[];
      Map<String, Object?> response(String project) => {
        'config': {
          'plugins': {
            'sample@local': {'enabled': true},
          },
        },
        'layers': [
          {
            'name': {'type': 'user', 'file': '/$project/config.toml'},
            'version': project,
          },
        ],
      };
      store = CodexCustomizationStore(
        disk: disk,
        request: (method, params) async {
          observed.add((method, params));
          if (method == 'config/read') {
            final project = params['cwd'] as String;
            if (project == 'A' && firstA) {
              firstA = false;
              return delayedA.future;
            }
            return response(project);
          }
          if (method == 'config/value/write') return {};
          throw StateError(method);
        },
      );
      final old = store.list(CustomizationKind.plugins, project: 'A');
      final current = (await store.list(
        CustomizationKind.plugins,
        project: 'B',
      )).singleWhere((i) => i.name == 'sample@local');
      delayedA.complete(response('A'));
      final stale = (await old).singleWhere((i) => i.name == 'sample@local');
      expect(store.canToggle(current), true);
      await store.setEnabled(current, true);
      expect(observed.last.$2['cwd'], 'B');
      expect(
        observed.where((c) => c.$1 == 'config/value/write').last.$2['filePath'],
        '/B/config.toml',
      );
      await store.setEnabled(stale, true);
      expect(observed.last.$2['cwd'], 'A');
      expect(
        observed.where((c) => c.$1 == 'config/value/write').last.$2['filePath'],
        '/A/config.toml',
      );
    },
  );
  test('native skill toggle uses reported absolute path', () async {
    final skill = (await store.list(
      CustomizationKind.skills,
      project: '/project',
    )).single;
    expect(skill.enabled, false);
    await store.setEnabled(skill, true);
    expect(calls.last.$1, 'skills/config/write');
    expect(calls.last.$2, {'path': skill.path, 'enabled': true});
  });
  test(
    'failed role registration rolls back only untouched unregistered template',
    () async {
      store = CodexCustomizationStore(
        disk: disk,
        request: (method, params) async {
          if (method == 'config/value/write') throw StateError('unsupported');
          return request(method, params);
        },
      );
      await expectLater(
        store.create(
          CustomizationKind.subagents,
          CustomizationScope.user,
          'helper',
        ),
        throwsStateError,
      );
      expect(disk.data, isEmpty);
      disk.data['/custom/codex/agents/helper.toml'] = 'existing';
      await expectLater(
        store.create(
          CustomizationKind.subagents,
          CustomizationScope.user,
          'helper',
        ),
        throwsA(isA<Exception>()),
      );
      expect(disk.data['/custom/codex/agents/helper.toml'], 'existing');
    },
  );
  test('failed registration preserves concurrent user edits', () async {
    store = CodexCustomizationStore(
      disk: disk,
      request: (method, params) async {
        if (method == 'config/value/write') {
          disk.data['/custom/codex/agents/helper.toml'] = 'edited';
          throw StateError('unsupported');
        }
        return request(method, params);
      },
    );
    await expectLater(
      store.create(
        CustomizationKind.subagents,
        CustomizationScope.user,
        'helper',
      ),
      throwsStateError,
    );
    expect(disk.data['/custom/codex/agents/helper.toml'], 'edited');
  });
  test('agent creation registers native config_file', () async {
    final path = await store.create(
      CustomizationKind.subagents,
      CustomizationScope.project,
      'reviewer',
      project: '/project',
    );
    expect(path, '/project/.codex/agents/reviewer.toml');
    expect(calls.last.$1, 'config/value/write');
    expect(calls.last.$2['filePath'], '/project/.codex/config.toml');
    expect(calls.last.$2['value'], {
      'description': 'Custom Codex agent reviewer',
      'config_file': path,
    });
  });
  test(
    'MCP allowlist prevents pretending an excluded tool is enabled',
    () async {
      config = {
        'mcp_servers': {
          'files': {
            'enabled_tools': ['read'],
          },
        },
      };
      final items = await store.list(CustomizationKind.mcps);
      final tool = items.singleWhere((i) => i.name == 'files / write');
      expect(tool.enabled, false);
      await expectLater(store.setEnabled(tool, true), throwsStateError);
      expect(calls.where((call) => call.$1 == 'config/value/write'), isEmpty);
    },
  );
  test(
    'shadowed config write reports failure, not fake toggle success',
    () async {
      config = {
        'plugins': {
          'sample@local': {'enabled': true},
        },
      };
      final plugin = (await store.list(CustomizationKind.plugins))
          .singleWhere((i) => i.name == 'sample@local');
      await expectLater(store.setEnabled(plugin, false), throwsStateError);
      final write = calls
          .singleWhere((call) => call.$1 == 'config/value/write')
          .$2;
      expect(write['keyPath'], 'plugins."sample@local".enabled');
      expect(write['expectedVersion'], 'v1');
    },
  );
  test(
    'MCP tool disable preserves exclusions and verifies effective config',
    () async {
      config = {
        'mcp_servers': {
          'files': {
            'disabled_tools': ['legacy'],
          },
        },
      };
      store = CodexCustomizationStore(
        disk: disk,
        request: (method, params) async {
          final result = await request(method, params);
          if (method == 'config/value/write') {
            ((config['mcp_servers'] as Map)['files'] as Map)['disabled_tools'] =
                params['value'];
          }
          return result;
        },
      );
      final tool = (await store.list(CustomizationKind.mcps))
          .singleWhere((i) => i.name == 'files / write');
      await store.setEnabled(tool, false);
      final write = calls.singleWhere((c) => c.$1 == 'config/value/write').$2;
      expect(write['value'], ['legacy', 'write']);
      expect(write['keyPath'], 'mcp_servers."files".disabled_tools');
    },
  );
  test(
    'unavailable config path blocks edits instead of guessing home',
    () async {
      final unsupported = CodexCustomizationStore(
        disk: disk,
        request: (_, _) async => {},
      );
      await expectLater(
        unsupported.list(CustomizationKind.rules),
        throwsStateError,
      );
      expect(disk.data, isEmpty);
    },
  );
  test(
    'project prompts override user prompts; arguments stay literal text',
    () async {
      disk.data['/custom/codex/prompts/ship.md'] = 'User';
      disk.data['/project/.codex/prompts/ship.md'] =
          '---\ndescription: Ship changes\n---\nProject \$ARGUMENTS';
      final prompts = await CodexPrompt.load(store, project: '/project');
      expect(prompts.single.description, 'Ship changes');
      expect(
        CodexPrompt.expandInput('/ship \$(whoami) \$1', prompts),
        'Project \$(whoami) \$1',
      );
      expect(CodexPrompt.expandInput('/other hi', prompts), '/other hi');
      expect(
        CodexPrompt.expandInput('please /ship hi', prompts),
        'please /ship hi',
      );
    },
  );
}
