import 'dart:async';
import 'dart:convert';

import 'package:baocode/kernel/claude_code/claude_haiku.dart';
import 'package:baocode/usage/usage_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String text(String text) => jsonEncode({
    'type': 'stream_event',
    'event': {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    },
  });

  test('stream-json split bytes and UTF-8 emit before final result', () async {
    final input = StreamController<List<int>>();
    final chunks = <String>[];
    final timer = ClaudeAnswerTimer(onText: chunks.add);
    final done = input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => timer.add(line, Duration.zero));
    final bytes = utf8.encode('${text('你')}\n${text('好')}\n');
    for (final byte in bytes) {
      input.add([byte]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(chunks, ['你', '你好']);
    input.add(
      utf8.encode(
        '${jsonEncode({'type': 'result', 'is_error': false, 'result': '你好'})}\n',
      ),
    );
    await input.close();
    await done;
    expect(timer.answer('', 0).text, '你好');
    expect(chunks, ['你', '你好']);
  });

  test('stream accumulator stops retaining text after its size limit', () {
    final chunks = <String>[];
    final timer = ClaudeAnswerTimer(onText: chunks.add, maxTextLength: 4);
    timer.add(text('abc'), Duration.zero);
    timer.add(text('defghijkl'), Duration.zero);
    timer.add(text('ignored'), Duration.zero);
    expect(chunks, ['abc', 'abcde']);
    expect(() => timer.answer('', 0), throwsA(isA<ClaudeHaikuException>()));
  });

  test('an answer is timed from Claude Code starting its request', () {
    final timer = ClaudeAnswerTimer()
      ..add('{"type":"system","subtype":"init"}', const Duration(seconds: 2))
      ..add('not json', const Duration(seconds: 2))
      ..add(text('1 2'), const Duration(milliseconds: 2500))
      ..add(text(' 3'), const Duration(milliseconds: 4500))
      ..add(
        jsonEncode({
          'type': 'result',
          'is_error': false,
          'result': '1 2 3',
          'usage': {'output_tokens': 120},
        }),
        const Duration(seconds: 5),
      );
    final answer = timer.answer('', 0);
    expect(answer.text, '1 2 3');
    expect(answer.firstText, const Duration(milliseconds: 500));
    expect(answer.lastText, const Duration(milliseconds: 2500));
    expect(answer.tokensPerSecond, 60);
  });

  test('no speed without a count, or with all the text at once', () {
    String result(Map<String, Object?> usage) => jsonEncode({
      'type': 'result',
      'is_error': false,
      'result': '1',
      'usage': usage,
    });
    final uncounted = ClaudeAnswerTimer()
      ..add(text('1'), const Duration(seconds: 1))
      ..add(text('2'), const Duration(seconds: 2))
      ..add(result({'output_tokens': 0}), const Duration(seconds: 2));
    expect(uncounted.answer('', 0).tokensPerSecond, isNull);
    final whole = ClaudeAnswerTimer()
      ..add(text('1 2 3'), const Duration(seconds: 1))
      ..add(result({'output_tokens': 9}), const Duration(seconds: 1));
    expect(whole.answer('', 0).tokensPerSecond, isNull);
  });

  test('an error result is thrown', () {
    final timer = ClaudeAnswerTimer()
      ..add(
        jsonEncode({
          'type': 'result',
          'is_error': true,
          'result': 'API Error: 401',
        }),
        Duration.zero,
      );
    expect(
      () => timer.answer('', 1),
      throwsA(
        isA<ClaudeHaikuException>().having(
          (e) => e.message,
          'message',
          'API Error: 401',
        ),
      ),
    );
    expect(
      () => ClaudeAnswerTimer().answer('boom', 1),
      throwsA(isA<ClaudeHaikuException>()),
    );
  });

  test('a call of Claude\'s own is kept from its result, under the '
      'conversation it was for', () {
    final at = DateTime(2026, 11, 1, 12);
    final call = claudeHaikuCall(
      {
        'type': 'result',
        'duration_ms': 1500,
        'usage': {
          'input_tokens': 120,
          'output_tokens': 9,
          'cache_read_input_tokens': 4000,
          'cache_creation_input_tokens': 0,
        },
        'modelUsage': {'claude-haiku-4-5-20251001': <String, Object?>{}},
      },
      at: at,
      session: 'conversation-1',
    )!;
    expect(call.session, 'conversation-1');
    expect(call.requestClass, UsageClass.auxiliary);
    expect(call.model, 'claude-haiku-4-5');
    expect(call.input, 120);
    expect(call.output, 9);
    expect(call.cacheRead, 4000);
    expect(call.at, at.subtract(const Duration(milliseconds: 1500)));
    expect(claudeHaikuCall({'type': 'result'}, at: at), isNull);
  });

  test('a provider is told the conversation in a header of its own, after '
      'its own headers', () {
    expect(
      withUsageSession({'A': '1'}, 's1')['ANTHROPIC_CUSTOM_HEADERS'],
      'x-baocode-session: s1',
    );
    expect(
      withUsageSession({
        'ANTHROPIC_CUSTOM_HEADERS': 'X-Team: a',
      }, 's1')['ANTHROPIC_CUSTOM_HEADERS'],
      'X-Team: a\nx-baocode-session: s1',
    );
  });
}
