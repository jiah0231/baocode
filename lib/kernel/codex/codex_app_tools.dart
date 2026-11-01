import 'dart:async';
import 'dart:convert';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../claude_code/claude_sdk_tools.dart';

/// Codex's experimental dynamic tools backed by the same checked app-tool
/// registry as Claude. Nothing is executed from a name alone: the registry
/// rechecks the bot's current ability gate on every call.
class CodexAppTools {
  CodexAppTools(this.cwd);

  /// Reviewed bot isolation requires the reviewed stable Codex 0.166.x family. The official
  /// initialize userAgent prefix is `<client-originator>/<Cargo package version>`,
  /// e.g. baocode/0.166.0 (Windows ...), not the client's supplied version.
  /// Unknown or prerelease formats fail closed instead of assuming that
  /// older servers enforce feature/config overrides they might ignore.
  static bool supportsRestrictedBots(Object? userAgent) {
    if (userAgent is! String) return false;
    final match = RegExp(r'^[A-Za-z0-9_.-]+/(\d+)\.(\d+)\.(\d+)(?:\s|$)')
        .firstMatch(userAgent);
    if (match == null) return false;
    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[2]!);
    final patch = int.tryParse(match[3]!);
    if (major == null || minor == null || patch == null) return false;
    return major == 0 && minor == 166;
  }

  final String cwd;
  final _cancelled = <Completer<void>>{};

  Future<List<Map<String, Object?>>> specs() async {
    final response = await ClaudeSdkTools.handle({
      'id': 0,
      'method': 'tools/list',
    }, ClaudeSdkCall(cwd: cwd));
    final result = response['result'] as Map;
    return [
      {
        'type': 'function',
        'name': 'baocode_dispatch',
        'description': 'Discover or invoke the currently authorized BaoCode tools. Use operation=list to get names, descriptions and JSON schemas. Use operation=call with name and arguments to call one. Use this when a capability was enabled after this conversation began.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'operation': {
              'type': 'string',
              'enum': ['list', 'call'],
            },
            'name': {'type': 'string'},
            'arguments': {'type': 'object'},
          },
          'required': ['operation'],
        },
      },
      for (final tool in result['tools'] as List)
        {
          'type': 'function',
          'name': tool['name'],
          'description': tool['description'],
          'inputSchema': tool['inputSchema'],
        },
    ];
  }

  /// Do not pass an empty MCP table: Codex merges config layers. Disable
  /// every configured server/plugin explicitly and use a read-only sandbox
  /// in the caller as an independent boundary for native file changes.
  static Map<String, Object?> restrictedConfig(Map<String, Object?> config) {
    Map<String, Object?> disabled(Object? value) => {
      if (value is Map)
        for (final key in value.keys)
          if (key is String) key: {'enabled': false},
    };
    const features = {
      'standalone_web_search': false,
      'collab': false,
      'connectors': false,
      'multi_agent_v2_dynamic_tools': false,
      'image_generation': false,
      'imagegenext': false,
      'deferred_executor': false,
      'request_permissions_tool': false,
      'request_permissions': false,
      'memory_tool': false,
      'send_message_to_user_async': false,
      'send_async_message': false,
      'agent_message_board': false,
      'multi_agent_v2': false,
      'tool_suggest': false,
      'shell_tool': false,
      'view_image': false,
      'multi_agent': false,
      'js_repl': false,
      'js_repl_tools_only': false,
      'code_mode': false,
      'code_mode_only': false,
      'code_mode_host': false,
      'apps': false,
      'plugins': false,
      'hooks': false,
      'codex_hooks': false,
      'plugin_hooks': false,
      'goals': false,
      'computer_use': false,
      'browser_use': false,
      'browser_use_external': false,
    };
    return {
      'mcp_servers': disabled(config['mcp_servers']),
      'plugins': {
        ...disabled(config['plugins']),
        '_default': {'enabled': false},
      },
      'apps': {
        ...disabled(config['apps']),
        '_default': {'enabled': false},
      },
      'features': features,
      'notify': <String>[],
      'web_search': 'disabled',
      // Selected profiles can override top-level feature settings. Apply
      // the same policy there, without replacing the user's model/account.
      'profiles': {
        if (config['profiles'] case final Map profiles)
          for (final key in profiles.keys)
            if (key is String)
              key: {'features': features, 'web_search': 'disabled'},
      },
      'hooks': {
        for (final event in const [
          'SessionStart',
          'SessionEnd',
          'PreToolUse',
          'PostToolUse',
          'PreModelRequest',
          'PostModelRequest',
          'UserPromptSubmit',
          'PermissionRequest',
          'Stop',
          'SubagentStart',
          'SubagentStop',
          'PreCompact',
          'PostCompact',
          'Interrupt',
        ])
          event: <Object?>[],
      },
    };
  }

  static Map<String, Object?> instructions(KernelWorkspace workspace) => {
    if (workspace.ownPrompt)
      'baseInstructions':
          '${workspace.instructions}\nWhen a named BaoCode tool is not directly available, use baocode_dispatch (list to discover currently permitted tools, call to invoke one).',
    if (!workspace.ownPrompt && workspace.instructions.isNotEmpty)
      'developerInstructions': workspace.instructions,
  };

  Future<Map<String, Object?>> call(
    Map<String, Object?> params, {
    required String threadId,
  }) async {
    if (params['threadId'] != threadId ||
        (params['namespace'] != null && params['namespace'] != '') ||
        params['arguments'] is! Map ||
        params['tool'] is! String) {
      return _failure('Invalid or foreign BaoCode tool call.');
    }
    if (params['tool'] == 'baocode_dispatch') {
      final input = params['arguments'] as Map;
      if (input['operation'] == 'list') {
        final tools = await specs();
        return {
          'success': true,
          'contentItems': [
            {
              'type': 'inputText',
              'text': jsonEncode(
                tools.where((t) => t['name'] != 'baocode_dispatch').toList(),
              ),
            },
          ],
        };
      }
      if (input['operation'] != 'call' ||
          input['name'] == 'baocode_dispatch' ||
          input['name'] is! String ||
          input['arguments'] is! Map) {
        return _failure(
          'Use operation=list or call with a tool name and arguments.',
        );
      }
      return call({
        ...params,
        'tool': input['name'],
        'arguments': input['arguments'],
      }, threadId: threadId);
    }
    final cancel = Completer<void>();
    _cancelled.add(cancel);
    try {
      final answer = await ClaudeSdkTools.handle(
        {
          'id': params['callId'],
          'method': 'tools/call',
          'params': {
            'name': params['tool'],
            'arguments': params['arguments'],
            '_meta': {'claudecode/toolUseId': params['callId']},
          },
        },
        ClaudeSdkCall(cwd: cwd, sessionId: threadId, cancelled: cancel.future),
      );
      final result = answer['result'] as Map?;
      if (result == null) return _failure('BaoCode tool returned no result.');
      return {
        'success': result['isError'] != true && !cancel.isCompleted,
        'contentItems': [
          for (final block in result['content'] as List? ?? const [])
            if (block is Map && block['type'] == 'text')
              {'type': 'inputText', 'text': block['text'] ?? ''}
            else if (block is Map && block['type'] == 'image')
              {
                'type': 'inputImage',
                'imageUrl': 'data:${block['mimeType']};base64,${block['data']}',
              },
        ],
      };
    } on Object catch (error) {
      return _failure('$error');
    } finally {
      _cancelled.remove(cancel);
    }
  }

  void cancel() {
    for (final cancel in _cancelled) {
      if (!cancel.isCompleted) cancel.complete();
    }
    _cancelled.clear();
  }

  static Map<String, Object?> _failure(String message) => {
    'success': false,
    'contentItems': [
      {'type': 'inputText', 'text': message},
    ],
  };

  /// Preserve app tool identity, image delivery and bot message tagging in
  /// the existing mobile v1 ChatCodec; no mobile protocol change is needed.
  static ToolCallItem item(Map<String, Object?> item, {required bool done}) {
    var name = item['tool'] as String? ?? '';
    var input = (item['arguments'] as Map?)?.cast<String, Object?>() ?? {};
    if (name == 'baocode_dispatch' &&
        input['operation'] == 'call' &&
        input['name'] is String) {
      name = input['name'] as String;
      input = (input['arguments'] as Map?)?.cast<String, Object?>() ?? {};
    }
    final tool = ClaudeSdkTools.called('mcp__${ClaudeSdkTools.server}__$name');
    final content = item['contentItems'] as List? ?? const [];
    final text = [
      for (final block in content)
        if (block is Map && block['type'] == 'inputText') block['text'] ?? '',
    ].join('\n');
    return ToolCallItem(
      kind: tool?.kind ?? ToolKind.mcp,
      target: tool?.summary?.call(input, done ? text : null) ?? name,
      tool: name,
      callId: item['id'] as String?,
      input: input,
      output: done ? text : null,
      status: !done
          ? ToolStatus.running
          : item['success'] == false || item['status'] == 'failed'
          ? ToolStatus.failed
          : ToolStatus.succeeded,
      imageFiles: tool?.files?.call(text) ?? const [],
      images: [
        for (final block in content)
          if (block is Map && block['type'] == 'inputImage')
            ..._images(block['imageUrl']),
      ],
    );
  }

  static List<ImageAttachment> _images(Object? url) {
    if (url is! String || !url.startsWith('data:image/')) return const [];
    try {
      final data = UriData.parse(url);
      return [
        ImageAttachment(bytes: data.contentAsBytes(), mediaType: data.mimeType),
      ];
    } on FormatException {
      return const [];
    }
  }
}
