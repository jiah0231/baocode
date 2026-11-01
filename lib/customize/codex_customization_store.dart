import 'dart:convert';

import 'package:bao_remote/files.dart'
    show IdeFileExistsException, IdeFileNotFoundException;
import 'package:path/path.dart' as p;

import 'customization_disk.dart';
import 'customization_store.dart';
import 'customizations.dart';
import 'codex_settings_rpc.dart';

/// Codex's files and native settings. Never reads or writes .claude files.
/// CODEX_HOME is obtained from the server's user config layer, so custom
/// homes and SSH hosts are respected rather than guessed from this OS.
class CodexCustomizationStore extends CustomizationStore {
  CodexCustomizationStore({super.disk, this.location, this.request})
    : files = disk ?? CustomizationDisk.local;

  final CustomizationDisk? files;
  final String? location;
  final CodexSettingsRequest? request;
  p.Context get paths => files!.paths;
  // Metadata belongs to the exact immutable row, never to the latest list.
  // Concurrent category/project loads cannot overwrite one another.
  final _switches =
      Expando<
        ({
          String key,
          String? tool,
          String? skill,
          String? project,
          String userConfig,
        })
      >();

  Future<T> _rpc<T>(Future<T> Function(CodexSettingsRequest) body) =>
      request == null ? withCodexSettings(location, body) : body(request!);

  Future<Map<String, Object?>> _config(
    CodexSettingsRequest ask,
    String? project,
  ) async {
    final response = await ask('config/read', {
      'includeLayers': true,
      'cwd': ?project,
    });
    _userPath(response); // Reject unsupported schemas before exposing editors.
    return response;
  }

  String _userPath(Map<String, Object?> response) {
    for (final layer in response['layers'] as List? ?? const []) {
      if (layer is! Map || layer['name'] is! Map) continue;
      final name = layer['name'] as Map;
      if (name['type'] == 'user' &&
          name['profile'] == null &&
          name['file'] is String) {
        return name['file'] as String;
      }
    }
    throw StateError(
      'Codex did not report its user config path; update Codex before editing settings.',
    );
  }

  @override
  Future<String> config() =>
      _rpc((ask) async => paths.dirname(_userPath(await _config(ask, null))));

  @override
  bool get supported => files != null;
  @override
  bool get isLocal => files?.isLocal ?? true;
  @override
  Future<String> read(String path) async =>
      await files!.read(path) ?? (throw IdeFileNotFoundException(path));
  @override
  Future<bool> exists(String path) async =>
      await files!.isDirectory(path) == false;
  @override
  Future<void> write(String path, String text) => files!.write(path, text);
  @override
  Future<void> delete(Customization item) async {
    if (item.removePath case final path?) await files!.delete(path);
  }

  bool canCreate(CustomizationKind kind) =>
      kind == CustomizationKind.skills ||
      kind == CustomizationKind.commands ||
      kind == CustomizationKind.subagents ||
      kind == CustomizationKind.rules;

  bool canToggle(Customization item) => _switches[item] != null;

  @override
  Future<List<Customization>> list(
    CustomizationKind kind, {
    String? project,
  }) async {
    if (!supported) return [];
    return _rpc((ask) async {
      final response = await _config(ask, project);
      final config = (response['config'] as Map?) ?? {};
      final userConfig = _userPath(response);
      final home = paths.dirname(userConfig);
      if (kind == CustomizationKind.skills) {
        final result = await ask('skills/list', {
          'cwds': [?project],
          'forceReload': true,
        });
        final items = <Customization>[];
        final seen = <String>{};
        for (final entry in result['data'] as List? ?? const []) {
          if (entry is! Map) continue;
          final cwd = entry['cwd'];
          if (project != null &&
              (cwd is! String || !paths.equals(cwd, project))) {
            continue;
          }
          for (final raw in entry['skills'] as List? ?? const []) {
            if (raw is! Map ||
                raw['path'] is! String ||
                raw['name'] is! String) {
              continue;
            }
            final path = raw['path'] as String;
            if (!seen.add(path)) continue;
            final projectOwned =
                project != null && paths.isWithin(project, path);
            final editable =
                (raw['scope'] == 'user' || raw['scope'] == 'repo') &&
                raw['pluginId'] == null;
            final item = Customization(
              kind: kind,
              scope: projectOwned
                  ? CustomizationScope.project
                  : CustomizationScope.user,
              name: raw['name'] as String,
              path: path,
              description: raw['description'] as String? ?? '',
              editable: editable,
              enabled: raw['enabled'] as bool? ?? true,
              removePath: editable ? paths.dirname(path) : null,
            );
            items.add(item);
            _switches[item] = (
              key: '',
              tool: null,
              skill: path,
              project: project,
              userConfig: userConfig,
            );
          }
        }
        return items;
      }
      if (kind == CustomizationKind.commands) {
        return [
          ...await _markdown(
            kind,
            CustomizationScope.user,
            paths.join(home, 'prompts'),
          ),
          if (project != null)
            ...await _markdown(
              kind,
              CustomizationScope.project,
              paths.join(project, '.codex', 'prompts'),
            ),
        ];
      }
      if (kind == CustomizationKind.rules) {
        return [
          _file(
            kind,
            CustomizationScope.user,
            'AGENTS.md',
            paths.join(home, 'AGENTS.md'),
            '# Codex instructions\n',
          ),
          ...await _markdown(
            kind,
            CustomizationScope.user,
            paths.join(home, 'rules'),
            suffix: '.rules',
          ),
          if (project != null) ...[
            _file(
              kind,
              CustomizationScope.project,
              'AGENTS.md',
              paths.join(project, 'AGENTS.md'),
              '# Project instructions\n',
            ),
            ...await _markdown(
              kind,
              CustomizationScope.project,
              paths.join(project, '.codex', 'rules'),
              suffix: '.rules',
            ),
          ],
        ];
      }
      final section = switch (kind) {
        CustomizationKind.subagents => 'agents',
        CustomizationKind.mcps => 'mcp_servers',
        CustomizationKind.hooks => 'hooks',
        CustomizationKind.plugins => 'plugins',
        _ => '',
      };
      final entries = config[section] as Map? ?? {};
      final items = <Customization>[
        _file(
          kind,
          CustomizationScope.user,
          'config.toml · $section',
          userConfig,
          '# Codex configuration\n',
        ),
        if (project != null)
          _file(
            kind,
            CustomizationScope.project,
            '.codex/config.toml · $section',
            paths.join(project, '.codex', 'config.toml'),
            '# Project Codex configuration\n',
          ),
      ];
      Map<String, Object?> statuses = {};
      if (kind == CustomizationKind.mcps && entries.isNotEmpty) {
        // Tool names come from the installed server, not invented UI entries.
        final data = <Object?>[];
        final seen = <String>{};
        String? cursor;
        do {
          final page = await ask('mcpServerStatus/list', {
            'limit': 100,
            'cursor': ?cursor,
          });
          data.addAll(page['data'] as List? ?? []);
          cursor = page['nextCursor'] as String?;
        } while (cursor != null && seen.add(cursor));
        statuses = {'data': data};
      }
      for (final entry in entries.entries) {
        final name = entry.key.toString();
        final value = entry.value;
        if (value is! Map && kind != CustomizationKind.hooks) continue;
        final map = value is Map ? value : const {};
        if (kind == CustomizationKind.plugins && name == 'default') continue;
        String? agentFile;
        if (kind == CustomizationKind.subagents &&
            map['config_file'] is String) {
          final file = map['config_file'] as String;
          String? originFile;
          for (final layer in response['layers'] as List? ?? []) {
            if (layer is! Map ||
                layer['name'] is! Map ||
                layer['config'] is! Map) {
              continue;
            }
            final agents = (layer['config'] as Map)['agents'];
            if (agents is Map &&
                agents[name] is Map &&
                (agents[name] as Map)['config_file'] == file) {
              final source = layer['name'] as Map;
              originFile = source['file'] as String?;
              if (source['type'] == 'project' &&
                  source['dotCodexFolder'] is String) {
                originFile = paths.join(
                  source['dotCodexFolder'] as String,
                  'config.toml',
                );
              }
            }
          }
          // Never guess a relative role file's base when provenance is absent.
          agentFile = paths.isAbsolute(file)
              ? file
              : originFile == null
              ? null
              : paths.join(paths.dirname(originFile), file);
        }
        final item = Customization(
          kind: kind,
          scope: CustomizationScope.user,
          name: name,
          path: agentFile ?? userConfig,
          description:
              map['description'] as String? ??
              (kind == CustomizationKind.hooks
                  ? 'Codex lifecycle hook; requires support in the installed CLI.'
                  : 'Codex $section configuration'),
          detail: const JsonEncoder.withIndent('  ').convert(value),
          editable: true,
          enabled:
              kind == CustomizationKind.mcps ||
                  kind == CustomizationKind.plugins
              ? map['enabled'] != false
              : null,
        );
        items.add(item);
        if (kind == CustomizationKind.mcps ||
            kind == CustomizationKind.plugins) {
          _switches[item] = (
            key: '$section.${jsonEncode(name)}.enabled',
            tool: null,
            skill: null,
            project: project,
            userConfig: userConfig,
          );
        }
        if (kind != CustomizationKind.mcps) continue;
        for (final raw in statuses['data'] as List? ?? const []) {
          if (raw is! Map || raw['name'] != name) continue;
          final tools = raw['tools'] as Map? ?? {};
          final disabled = (map['disabled_tools'] as List? ?? [])
              .whereType<String>()
              .toSet();
          final allowed = (map['enabled_tools'] as List?)
              ?.whereType<String>()
              .toSet();
          for (final tool in tools.keys.whereType<String>()) {
            final toolItem = Customization(
              kind: kind,
              scope: CustomizationScope.user,
              name: '$name / $tool',
              path: userConfig,
              description: 'Codex MCP tool',
              enabled:
                  !disabled.contains(tool) &&
                  (allowed == null || allowed.contains(tool)),
            );
            items.add(toolItem);
            _switches[toolItem] = (
              key: 'mcp_servers.${jsonEncode(name)}',
              tool: tool,
              skill: null,
              project: project,
              userConfig: userConfig,
            );
          }
        }
      }
      return items;
    });
  }

  Customization _file(
    CustomizationKind kind,
    CustomizationScope scope,
    String name,
    String path,
    String initial,
  ) => Customization(
    kind: kind,
    scope: scope,
    name: name,
    path: path,
    detail: initial,
    description: 'Codex file · changes apply to new sessions',
  );

  Future<List<Customization>> _markdown(
    CustomizationKind kind,
    CustomizationScope scope,
    String directory, {
    String suffix = '.md',
  }) async => [
    for (final entry in await files!.children(directory))
      if (!entry.directory && entry.path.endsWith(suffix))
        Customization(
          kind: kind,
          scope: scope,
          name: paths.basenameWithoutExtension(entry.path),
          path: entry.path,
          removePath: entry.path,
          description: describeMarkdown(await files!.read(entry.path) ?? ''),
        ),
  ];

  @override
  Future<String> create(
    CustomizationKind kind,
    CustomizationScope scope,
    String name, {
    String? project,
  }) async {
    if (!canCreate(kind) ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(name)) {
      throw ArgumentError(
        'Use letters, digits, hyphens or underscores for a Codex name.',
      );
    }
    if (scope != CustomizationScope.user && project == null) {
      throw ArgumentError('Select a project first.');
    }
    final root = scope == CustomizationScope.user
        ? await config()
        : paths.join(project!, '.codex');
    final skillRoot = scope == CustomizationScope.user
        ? paths.join(
            (await files!.homeDir()) ??
                (throw StateError('Home directory unavailable')),
            '.agents',
          )
        : paths.join(project!, '.agents');
    final path = switch (kind) {
      CustomizationKind.skills => paths.join(
        skillRoot,
        'skills',
        name,
        'SKILL.md',
      ),
      CustomizationKind.commands => paths.join(root, 'prompts', '$name.md'),
      CustomizationKind.subagents => paths.join(root, 'agents', '$name.toml'),
      _ => paths.join(root, 'rules', '$name.rules'),
    };
    if (await files!.isDirectory(path) != null) {
      throw IdeFileExistsException(path);
    }
    final initial = switch (kind) {
      CustomizationKind.skills =>
        '---\nname: $name\ndescription: When Codex should use this skill.\n---\n\n# $name\n\nInstructions for Codex.\n',
      CustomizationKind.commands =>
        '---\ndescription: What /$name does.\n---\n\nHelp with \$ARGUMENTS\n',
      CustomizationKind.subagents =>
        'developer_instructions = "Describe the role of this agent."\n',
      _ => '# Codex execution policy (Starlark)\n# prefix_rule(pattern = ["example"], decision = "prompt")\n',
    };
    await write(path, initial);
    if (kind == CustomizationKind.subagents) {
      try {
        await _rpc((ask) async {
          final userConfig = _userPath(await _config(ask, project));
          await ask('config/value/write', {
            'keyPath': 'agents.${jsonEncode(name)}',
            'value': {
              'description': 'Custom Codex agent $name',
              'config_file': path,
            },
            'mergeStrategy': 'upsert',
            'filePath': scope == CustomizationScope.user
                ? userConfig
                : paths.join(project!, '.codex', 'config.toml'),
          });
        });
      } on Object {
        // A timeout may have committed the native config. Verify absence
        // before removing the newly created file, and preserve user edits.
        try {
          final response = await _rpc((ask) => _config(ask, project));
          final effective = response['config'] as Map? ?? {};
          final agents = effective['agents'] as Map? ?? {};
          final role = agents[name] as Map? ?? {};
          var registered = role['config_file'] == path;
          for (final layer in response['layers'] as List? ?? []) {
            if (layer is! Map || layer['config'] is! Map) continue;
            final roles = (layer['config'] as Map)['agents'];
            if (roles is Map &&
                roles[name] is Map &&
                (roles[name] as Map)['config_file'] == path) {
              registered = true;
            }
          }
          if (!registered && await files!.read(path) == initial) {
            await files!.delete(path);
          }
        } on Object {
          // Keep the file if commit outcome cannot be established.
        }
        rethrow;
      }
    }
    return path;
  }

  @override
  Future<String?> configFile(
    CustomizationKind kind,
    CustomizationScope scope, {
    String? project,
  }) async => scope == CustomizationScope.user
      ? paths.join(await config(), 'config.toml')
      : project == null
      ? null
      : paths.join(project, '.codex', 'config.toml');

  Future<void> setEnabled(Customization item, bool enabled) async {
    final change = _switches[item];
    if (change == null) {
      throw StateError('This item has no supported Codex toggle.');
    }
    await _rpc((ask) async {
      if (change.skill case final path?) {
        await ask('skills/config/write', {'path': path, 'enabled': enabled});
        return;
      }
      final response = await _config(ask, change.project);
      if (_userPath(response) != change.userConfig) {
        throw StateError(
          'Codex config location changed; refresh settings before editing.',
        );
      }
      String? version;
      for (final layer in response['layers'] as List? ?? []) {
        if (layer is Map &&
            layer['name'] is Map &&
            (layer['name'] as Map)['file'] == change.userConfig) {
          version = layer['version'] as String?;
        }
      }
      var key = change.key;
      Object value = enabled;
      if (change.tool case final tool?) {
        final config = response['config'] as Map? ?? {};
        final servers = config['mcp_servers'] as Map? ?? {};
        final name = item.name.split(' / ').first;
        final server = servers[name] as Map? ?? {};
        final disabled = (server['disabled_tools'] as List? ?? [])
            .whereType<String>()
            .toSet();
        final allowed = (server['enabled_tools'] as List?)
            ?.whereType<String>()
            .toSet();
        if (enabled && allowed != null && !allowed.contains(tool)) {
          throw StateError(
            'This tool is excluded by enabled_tools. Edit the Codex config allowlist first.',
          );
        }
        enabled ? disabled.remove(tool) : disabled.add(tool);
        key = '$key.disabled_tools';
        value = disabled.toList()..sort();
      }
      await ask('config/value/write', {
        'keyPath': key,
        'value': value,
        'mergeStrategy': 'replace',
        'filePath': change.userConfig,
        'expectedVersion': ?version,
      });
      // A higher-priority project/admin layer can shadow a user write.
      // Report that instead of presenting an ineffective toggle as success.
      final effective =
          (await _config(ask, change.project))['config'] as Map? ?? {};
      final section = item.kind == CustomizationKind.plugins
          ? 'plugins'
          : 'mcp_servers';
      final entries = effective[section] as Map? ?? {};
      final name = change.tool == null
          ? item.name
          : item.name.split(' / ').first;
      final entry = entries[name] as Map? ?? {};
      final applied = change.tool == null
          ? (entry['enabled'] != false) == enabled
          : ((entry['disabled_tools'] as List? ?? []).contains(change.tool) ==
                !enabled);
      if (!applied) {
        throw StateError(
          'A higher-priority Codex configuration overrides this setting. Edit its project or managed config instead.',
        );
      }
    });
  }
}
