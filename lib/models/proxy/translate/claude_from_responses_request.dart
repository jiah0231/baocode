import 'dart:convert';

import 'common.dart';
import 'json_value.dart';

/// An OpenAI Responses request ([request], decoded or as JSON text: what
/// the Codex CLI sends) as an Anthropic Messages request for [model]: its
/// instructions and developer messages as the system prompt, its input as
/// messages, its function tools as tools.
///
/// What the model thought goes along as it came back from
/// [ResponsesFromClaudeTranslator]: a reasoning item's summary is a
/// `thinking` block, its encrypted content that block's signature (none:
/// redacted thinking).
///
/// [thinkingEffort] asks Anthropic's API for thinking at that effort, for
/// an upstream that speaks it; null leaves the effort to the caller (the
/// proxy asks the others for it after the model's name).
/// [maxTokens] is what Anthropic's API requires of every request; the
/// others have none.
Map<String, Object?> convertResponsesRequestToClaude(
  Object? request, {
  required String model,
  String? thinkingEffort,
  int? maxTokens,
}) {
  final root = JsonValue.of(request);
  final out = <String, Object?>{'model': model, 'stream': true};
  if (maxTokens != null) out['max_tokens'] = maxTokens;

  final system = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];
  String? role;
  var blocks = <Map<String, Object?>>[];

  void flush() {
    if (role != null && blocks.isNotEmpty) {
      messages.add({
        'role': role,
        // Results of the calls before the rest: what the API asks of a
        // message that answers tool calls.
        'content': role == 'user'
            ? [
                for (final block in blocks)
                  if (block['type'] == 'tool_result') block,
                for (final block in blocks)
                  if (block['type'] != 'tool_result') block,
              ]
            : blocks,
      });
    }
    blocks = [];
    role = null;
  }

  void add(String to, Map<String, Object?> block) {
    if (role != to) {
      flush();
      role = to;
    }
    blocks.add(block);
  }

  final instructions = root.get('instructions').string;
  if (instructions.trim().isNotEmpty) {
    system.add({'type': 'text', 'text': instructions});
  }

  final input = root.get('input');
  if (input.isString) {
    if (input.string.isNotEmpty) {
      add('user', {'type': 'text', 'text': input.string});
    }
  } else if (input.isArray) {
    for (final item in input.array) {
      final type = switch (item.get('type').string) {
        '' => 'message',
        final type => type,
      };
      switch (type) {
        case 'message':
          final from = item.get('role').string;
          final content = _contentBlocks(item.get('content'));
          if (from == 'developer' || from == 'system') {
            final text = [
              for (final block in content)
                if (block['type'] == 'text') block['text'],
            ].join('\n\n');
            if (text.isEmpty) continue;
            // Before the conversation: the system prompt; after it, said
            // as a reminder, as Claude Code's own are.
            if (messages.isEmpty && role == null) {
              system.add({'type': 'text', 'text': text});
            } else {
              add('user', {'type': 'text', 'text': systemReminderText(text)});
            }
            continue;
          }
          final to = from == 'assistant' ? 'assistant' : 'user';
          for (final block in content) {
            // An assistant's words are text, whatever its parts say.
            if (to == 'assistant' && block['type'] != 'text') continue;
            add(to, block);
          }
        case 'function_call':
          final arguments = JsonValue.parse(item.get('arguments').string);
          add('assistant', {
            'type': 'tool_use',
            'id': item.get('call_id').string,
            'name': item.get('name').string,
            'input': arguments.isObject ? arguments.value : <String, Object?>{},
          });
        case 'custom_tool_call':
          add('assistant', {
            'type': 'tool_use',
            'id': item.get('call_id').string,
            'name': item.get('name').string,
            'input': {'input': item.get('input').string},
          });
        case 'function_call_output' || 'custom_tool_call_output':
          final output = item.get('output');
          add('user', {
            'type': 'tool_result',
            'tool_use_id': item.get('call_id').string,
            'content': switch (output) {
              _ when output.isString => output.string,
              _ when output.isArray => _contentBlocks(output),
              _ when output.exists && !output.isNull => output.raw,
              _ => '',
            },
          });
        case 'reasoning':
          final text = [
            for (final part in item.get('summary').array)
              part.get('text').string,
          ].where((text) => text.isNotEmpty).join('\n\n');
          final signature = item.get('encrypted_content').string;
          if (text.isNotEmpty) {
            add('assistant', {
              'type': 'thinking',
              'thinking': text,
              'signature': signature,
            });
          } else if (signature.isNotEmpty) {
            add('assistant', {'type': 'redacted_thinking', 'data': signature});
          }
      }
    }
  }
  flush();

  if (system.isNotEmpty) out['system'] = system;
  out['messages'] = messages;

  final tools = [
    for (final tool in root.get('tools').array)
      // What Anthropic's API has a counterpart of: the functions. The
      // tools OpenAI hosts (web search, image generation) it has not.
      if (tool.get('type').string == 'function')
        {
          'name': tool.get('name').string,
          'description': tool.get('description').string,
          'input_schema': switch (tool.get('parameters')) {
            final schema when schema.isObject => schema.value,
            _ => <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{},
            },
          },
        },
  ];
  if (tools.isNotEmpty) {
    out['tools'] = tools;
    final choice = root.get('tool_choice');
    final parallel = root.get('parallel_tool_calls').value != false;
    Map<String, Object?> choose(String type) => {
      'type': type,
      if (!parallel && type != 'none') 'disable_parallel_tool_use': true,
    };
    if (choice.isString) {
      switch (choice.string) {
        case 'required':
          out['tool_choice'] = choose('any');
        case 'none':
          out['tool_choice'] = choose('none');
        default:
          if (!parallel) out['tool_choice'] = choose('auto');
      }
    } else if (choice.get('type').string == 'function') {
      out['tool_choice'] = {
        'type': 'tool',
        'name': choice.get('name').string.isNotEmpty
            ? choice.get('name').string
            : choice.get('function.name').string,
        if (!parallel) 'disable_parallel_tool_use': true,
      };
    } else if (!parallel) {
      out['tool_choice'] = choose('auto');
    }
  }

  if (thinkingEffort != null && thinkingEffort != 'none') {
    out['thinking'] = {
      'type': 'enabled',
      'budget_tokens': _thinkingBudget(thinkingEffort, maxTokens),
    };
  }

  // The conversation, for what keys it: the cache key of the session the
  // request is of, as Claude Code's `metadata.user_id` says it.
  final session = root.get('prompt_cache_key').string;
  if (session.isNotEmpty) {
    out['metadata'] = {
      'user_id': jsonEncode({'session_id': session}),
    };
  }
  return out;
}

/// What [effort] comes to as a thinking budget, under [maxTokens] (the
/// API wants less of it than the reply may be): the levels' usual budgets.
int _thinkingBudget(String effort, int? maxTokens) {
  final budget = switch (effort) {
    'minimal' => 1024,
    'low' => 2048,
    'medium' || 'auto' => 8192,
    'high' => 16000,
    _ => 24000,
  };
  final most = (maxTokens ?? 32000) - 1024;
  return most < budget ? (most < 1024 ? 1024 : most) : budget;
}

/// [content] (a text, or the parts of a message or a tool's output) as
/// Anthropic's blocks: text and pictures; the parts it has no counterpart
/// of are left out.
List<Map<String, Object?>> _contentBlocks(JsonValue content) {
  if (content.isString) {
    return content.string.isEmpty
        ? const []
        : [
            {'type': 'text', 'text': content.string},
          ];
  }
  final blocks = <Map<String, Object?>>[];
  for (final part in content.array) {
    switch (part.get('type').string) {
      case 'input_text' || 'output_text' || 'text':
        final text = part.get('text').string;
        if (text.isNotEmpty) blocks.add({'type': 'text', 'text': text});
      case 'input_image':
        final url = switch (part.get('image_url')) {
          final value when value.isObject => value.get('url').string,
          final value => value.string,
        };
        if (_image(url) case final image?) blocks.add(image);
    }
  }
  return blocks;
}

/// A picture as Anthropic's blocks have it: its bytes, from a `data:` URL,
/// or where it is.
Map<String, Object?>? _image(String url) {
  if (url.isEmpty) return null;
  final data = RegExp(r'^data:([^;,]+);base64,(.*)$', dotAll: true);
  if (data.firstMatch(url) case final match?) {
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': match.group(1),
        'data': match.group(2),
      },
    };
  }
  return {
    'type': 'image',
    'source': {'type': 'url', 'url': url},
  };
}
