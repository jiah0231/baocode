import 'dart:convert';

import 'package:baocode/models/proxy/translate/claude_from_responses_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ultra stays a named adaptive effort, never a guessed budget', () {
    final claude = convertResponsesRequestToClaude(
      {'input': 'hi'},
      model: 'gpt-6.1-sol',
      thinkingEffort: 'ultra',
      maxTokens: 32000,
    );
    expect(claude['thinking'], {'type': 'adaptive'});
    expect(claude['output_config'], {'effort': 'ultra'});
  });

  test('instructions and the conversation as Anthropic\'s messages', () {
    final claude = convertResponsesRequestToClaude({
      'model': 'gpt-5',
      'instructions': 'Be brief.',
      'input': [
        {
          'type': 'message',
          'role': 'developer',
          'content': [
            {'type': 'input_text', 'text': 'Answer in English.'},
          ],
        },
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'read a.txt'},
          ],
        },
      ],
      'tools': [
        {
          'type': 'function',
          'name': 'Read',
          'description': 'Reads a file',
          'parameters': {
            'type': 'object',
            'properties': {
              'file_path': {'type': 'string'},
            },
          },
        },
        {'type': 'web_search'},
      ],
      'tool_choice': 'required',
      'prompt_cache_key': 'baocode-1',
    }, model: 'gpt-5');

    expect(claude['model'], 'gpt-5');
    expect(claude['stream'], isTrue);
    // Anthropic's wants one; the Codex CLI names none.
    expect(claude.containsKey('max_tokens'), isFalse);
    expect(claude['system'], [
      {'type': 'text', 'text': 'Be brief.'},
      {'type': 'text', 'text': 'Answer in English.'},
    ]);
    expect(claude['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'read a.txt'},
        ],
      },
    ]);
    // The tools Anthropic's API has a counterpart of, the hosted ones out.
    expect(claude['tools'], [
      {
        'name': 'Read',
        'description': 'Reads a file',
        'input_schema': {
          'type': 'object',
          'properties': {
            'file_path': {'type': 'string'},
          },
        },
      },
    ]);
    expect(claude['tool_choice'], {'type': 'any'});
    expect(jsonDecode((claude['metadata'] as Map)['user_id'] as String), {
      'session_id': 'baocode-1',
    });
  });

  test('calls and their results as tool uses and results', () {
    final claude = convertResponsesRequestToClaude({
      'model': 'gpt-5',
      'input': [
        {'type': 'message', 'role': 'user', 'content': 'read a.txt'},
        {
          'type': 'reasoning',
          'summary': [
            {'type': 'summary_text', 'text': 'Reading.'},
          ],
          'encrypted_content': 'sig',
        },
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'Read',
          'arguments': '{"file_path":"a.txt"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': 'hello',
        },
      ],
    }, model: 'gpt-5');
    expect(claude['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'read a.txt'},
        ],
      },
      {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': 'Reading.', 'signature': 'sig'},
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'Read',
            'input': {'file_path': 'a.txt'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'call_1', 'content': 'hello'},
        ],
      },
    ]);
  });

  test('reasoning comes back as thinking, encrypted only as redacted', () {
    final claude = convertResponsesRequestToClaude({
      'model': 'gpt-5',
      'input': [
        {'type': 'message', 'role': 'user', 'content': 'hi'},
        {'type': 'reasoning', 'summary': const [], 'encrypted_content': 'sig'},
      ],
    }, model: 'gpt-5');
    expect(claude['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      },
      {
        'role': 'assistant',
        'content': [
          {'type': 'redacted_thinking', 'data': 'sig'},
        ],
      },
    ]);
  });

  test('a developer message after the conversation is a reminder', () {
    final claude = convertResponsesRequestToClaude({
      'model': 'gpt-5',
      'input': [
        {'type': 'message', 'role': 'user', 'content': 'hi'},
        {'type': 'message', 'role': 'developer', 'content': 'Keep it short.'},
      ],
    }, model: 'gpt-5');
    expect(claude['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
          {
            'type': 'text',
            'text': '<system-reminder>\nKeep it short.\n</system-reminder>',
          },
        ],
      },
    ]);
  });

  test('an effort asks Anthropic\'s API for its thinking budget', () {
    Map<String, Object?> thinking(String effort, {int? maxTokens}) =>
        convertResponsesRequestToClaude(
              {'model': 'claude-sonnet-4-5', 'input': 'hi'},
              model: 'claude-sonnet-4-5',
              thinkingEffort: effort,
              maxTokens: maxTokens ?? 32000,
            )['thinking']
            as Map<String, Object?>;

    expect(thinking('low'), {'type': 'enabled', 'budget_tokens': 2048});
    expect(thinking('high'), {'type': 'enabled', 'budget_tokens': 16000});
    expect(thinking('xhigh'), {'type': 'enabled', 'budget_tokens': 24000});
    // Less than the reply may be.
    expect(thinking('high', maxTokens: 4000), {
      'type': 'enabled',
      'budget_tokens': 2976,
    });
    final off = convertResponsesRequestToClaude(
      {'model': 'claude-sonnet-4-5', 'input': 'hi'},
      model: 'claude-sonnet-4-5',
      thinkingEffort: 'none',
      maxTokens: 32000,
    );
    expect(off.containsKey('thinking'), isFalse);
  });
}
