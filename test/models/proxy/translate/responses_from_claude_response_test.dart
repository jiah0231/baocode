import 'dart:convert';

import 'package:baocode/models/proxy/translate/claude_from_responses_request.dart';
import 'package:baocode/models/proxy/translate/responses_from_claude_response.dart';
import 'package:flutter_test/flutter_test.dart';

/// An Anthropic stream: a thought, a word, and a call to read a file.
const stream = [
  'event: message_start',
  'data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":5}}}',
  '',
  'event: content_block_start',
  'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Think"}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}',
  '',
  'event: content_block_stop',
  'data: {"type":"content_block_stop","index":0}',
  '',
  'event: content_block_start',
  'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}',
  '',
  'event: content_block_stop',
  'data: {"type":"content_block_stop","index":1}',
  '',
  'event: content_block_start',
  'data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"file_path\\":\\"a.txt\\"}"}}',
  '',
  'event: content_block_stop',
  'data: {"type":"content_block_stop","index":2}',
  '',
  'event: message_delta',
  'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}',
  '',
  'event: message_stop',
  'data: {"type":"message_stop"}',
];

/// What [translator] wrote for each of [lines].
List<String> feed(
  ResponsesFromClaudeTranslator translator,
  List<String> lines,
) => [for (final line in lines) ...translator.convert(line)];

/// The name and payload of each of [outputs].
List<(String, Map<String, Object?>)> eventsOf(List<String> outputs) => [
  for (final output in outputs)
    (
      output
          .split('\n')
          .firstWhere((line) => line.startsWith('event: '))
          .substring(7),
      Map<String, Object?>.from(
        jsonDecode(
          output
              .split('\n')
              .firstWhere((line) => line.startsWith('data: '))
              .substring(6),
        ) as Map,
      ),
    ),
];

void main() {
  test('Anthropic\'s stream as Responses\' events', () {
    final translator = ResponsesFromClaudeTranslator();
    final outputs = feed(translator, stream);
    expect(translator.finished, isTrue);

    final names = [
      for (final output in outputs) eventsOf([output]).single.$1,
    ];
    expect(names.first, 'response.created');
    expect(names.last, 'response.completed');
    expect(names, contains('response.reasoning_summary_text.delta'));
    expect(names, contains('response.output_text.delta'));
    expect(names, contains('response.function_call_arguments.delta'));

    final completed = eventsOf(outputs).last.$2['response']! as Map;
    expect(completed['status'], 'completed');
    final output = (completed['output']! as List).cast<Map>();
    expect(output[0]['type'], 'reasoning');
    expect(output[0]['summary'], [
      {'type': 'summary_text', 'text': 'Think'},
    ]);
    expect(output[0]['encrypted_content'], 'sig');
    expect(output[1]['type'], 'message');
    expect((output[1]['content'] as List).first['text'], 'Hello');
    expect(output[2]['type'], 'function_call');
    expect(output[2]['call_id'], 'toolu_1');
    expect(output[2]['name'], 'Read');
    expect(output[2]['arguments'], '{"file_path":"a.txt"}');
    // What the cache served is input too, as OpenAI counts it.
    expect(completed['usage'], {
      'input_tokens': 15,
      'input_tokens_details': {'cached_tokens': 5},
      'output_tokens': 7,
      'output_tokens_details': {'reasoning_tokens': 0},
      'total_tokens': 22,
    });
  });

  test('what it answers with goes back as thinking and calls', () {
    final translator = ResponsesFromClaudeTranslator();
    final outputs = feed(translator, stream);
    final response = eventsOf(outputs).last.$2['response']! as Map;
    final claude = convertResponsesRequestToClaude({
      'model': 'claude-sonnet-4-5',
      'input': [
        {'type': 'message', 'role': 'user', 'content': 'read a.txt'},
        ...(response['output']! as List),
      ],
    }, model: 'claude-sonnet-4-5');
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
          {'type': 'thinking', 'thinking': 'Think', 'signature': 'sig'},
          {'type': 'text', 'text': 'Hello'},
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'Read',
            'input': {'file_path': 'a.txt'},
          },
        ],
      },
    ]);
  });

  test('a stream that ends without its end fails the response', () {
    final translator = ResponsesFromClaudeTranslator();
    final outputs = [
      ...feed(translator, [
        'data: {"type":"message_start","message":{"id":"m"}}',
      ]),
      ...translator.abort('The upstream ended without a reply'),
    ];
    final events = eventsOf(outputs);
    expect(events.map((event) => event.$1), [
      'response.created',
      'response.failed',
    ]);
    final response = events.last.$2['response']! as Map;
    expect(response['status'], 'failed');
    expect(response['error'], {
      'code': 'server_error',
      'message': 'The upstream ended without a reply',
    });
    // Nothing more once it failed.
    expect(translator.convert('data: {"type":"message_stop"}'), isEmpty);
    expect(translator.abort('again'), isEmpty);
  });

  test('a stream with nothing in it still begins the response', () {
    final translator = ResponsesFromClaudeTranslator();
    final events = eventsOf(
      feed(translator, ['data: {"type":"message_stop"}']),
    );
    expect(events.map((event) => event.$1), [
      'response.created',
      'response.completed',
    ]);
  });
}
