import 'dart:convert';

import 'common.dart';
import 'json_value.dart';

/// A block of the message as it streams in: the item it becomes.
class _Block {
  _Block(this.kind, this.index, this.id);

  /// `message`, `reasoning` or `function_call`.
  final String kind;

  /// Its place in the response's output.
  final int index;
  final String id;
  String callId = '';
  String name = '';
  final StringBuffer text = StringBuffer();
  String signature = '';

  /// Redacted thinking: only the data.
  bool redacted = false;
}

/// Turns an Anthropic Messages stream into OpenAI Responses' server-sent
/// events, one `data:` line at a time ([convert]): what the Codex CLI reads
/// of an upstream. A text block is a message, a thinking block a reasoning
/// item (its signature the item's encrypted content, for
/// [convertResponsesRequestToClaude] to give back), a tool use a function
/// call.
class ResponsesFromClaudeTranslator {
  String _responseId = 'resp_${DateTime.now().microsecondsSinceEpoch}';
  var _started = false;
  var _finished = false;
  var _nextIndex = 0;
  var _inputTokens = 0;
  var _cachedTokens = 0;
  var _outputTokens = 0;
  String? _stopReason;
  final Map<int, _Block> _blocks = {};

  /// The items done, by their place in the output.
  final Map<int, Map<String, Object?>> _done = {};
  var _sequence = 0;

  /// Whether the stream ended as Anthropic's says it does.
  bool get finished => _finished;

  String _event(String name, Map<String, Object?> data) =>
      sseEvent(name, {'type': name, ...data, 'sequence_number': _sequence++});

  /// The events for one line of the upstream's stream: none for a line that
  /// is not `data:`.
  List<String> convert(String line) {
    if (!line.startsWith('data:') || _finished) return const [];
    final data = JsonValue.parse(line.substring(5).trim());
    return switch (data.get('type').string) {
      'message_start' => _messageStart(data),
      'content_block_start' => _blockStart(data),
      'content_block_delta' => _blockDelta(data),
      'content_block_stop' => _blockStop(data),
      'message_delta' => _messageDelta(data),
      'message_stop' => _messageStop(),
      'error' => _error(data),
      _ => const [],
    };
  }

  Map<String, Object?> get _usage => {
    'input_tokens': _inputTokens,
    'input_tokens_details': {'cached_tokens': _cachedTokens},
    'output_tokens': _outputTokens,
    'output_tokens_details': {'reasoning_tokens': 0},
    'total_tokens': _inputTokens + _outputTokens,
  };

  void _readUsage(JsonValue usage) {
    if (!usage.isObject) return;
    final input = usage.get('input_tokens');
    final cacheRead = usage.get('cache_read_input_tokens').integer;
    final cacheWrite = usage.get('cache_creation_input_tokens').integer;
    // Anthropic's input does not count what the cache served: OpenAI's does.
    if (input.exists) {
      _inputTokens = input.integer + cacheRead + cacheWrite;
      _cachedTokens = cacheRead;
    }
    final output = usage.get('output_tokens');
    if (output.exists) _outputTokens = output.integer;
  }

  List<String> _messageStart(JsonValue data) {
    if (_started) return const [];
    _started = true;
    final id = data.get('message.id').string;
    if (id.isNotEmpty) _responseId = 'resp_$id';
    _readUsage(data.get('message.usage'));
    return [
      _event('response.created', {'response': _response('in_progress')}),
    ];
  }

  Map<String, Object?> _response(
    String status, {
    Map<String, Object?>? extra,
  }) => {
    'id': _responseId,
    'object': 'response',
    'status': status,
    'output': [for (final index in _done.keys.toList()..sort()) _done[index]],
    ...?extra,
  };

  List<String> _blockStart(JsonValue data) {
    final events = <String>[];
    // A stream that opens with a block: the response is begun for it.
    if (!_started) events.addAll(_messageStart(JsonValue(const {})));
    final at = data.get('index').integer;
    final block = data.get('content_block');
    final index = _nextIndex++;
    switch (block.get('type').string) {
      case 'text':
        final item = _Block('message', index, 'msg_${index}_$_responseId');
        _blocks[at] = item;
        events.addAll([
          _event('response.output_item.added', {
            'output_index': index,
            'item': {
              'type': 'message',
              'id': item.id,
              'role': 'assistant',
              'status': 'in_progress',
              'content': const [],
            },
          }),
          _event('response.content_part.added', {
            'item_id': item.id,
            'output_index': index,
            'content_index': 0,
            'part': {
              'type': 'output_text',
              'text': '',
              'annotations': const [],
            },
          }),
        ]);
        if (block.get('text').string case final text when text.isNotEmpty) {
          events.addAll(_textDelta(item, text));
        }
      case 'thinking' || 'redacted_thinking':
        final item = _Block('reasoning', index, 'rs_${index}_$_responseId');
        item.redacted = block.get('type').string == 'redacted_thinking';
        if (item.redacted) item.signature = block.get('data').string;
        _blocks[at] = item;
        events.addAll([
          _event('response.output_item.added', {
            'output_index': index,
            'item': {
              'type': 'reasoning',
              'id': item.id,
              'summary': const [],
              if (item.redacted) 'encrypted_content': item.signature,
            },
          }),
          if (!item.redacted)
            _event('response.reasoning_summary_part.added', {
              'item_id': item.id,
              'output_index': index,
              'summary_index': 0,
              'part': {'type': 'summary_text', 'text': ''},
            }),
        ]);
      case 'tool_use':
        final item = _Block('function_call', index, 'fc_${index}_$_responseId')
          ..callId = block.get('id').string
          ..name = block.get('name').string;
        _blocks[at] = item;
        events.add(
          _event('response.output_item.added', {
            'output_index': index,
            'item': {
              'type': 'function_call',
              'id': item.id,
              'call_id': item.callId,
              'name': item.name,
              'arguments': '',
              'status': 'in_progress',
            },
          }),
        );
      default:
        // A block of another kind (a server tool's): no counterpart.
        _nextIndex--;
    }
    return events;
  }

  List<String> _textDelta(_Block item, String text) {
    item.text.write(text);
    return [
      _event('response.output_text.delta', {
        'item_id': item.id,
        'output_index': item.index,
        'content_index': 0,
        'delta': text,
      }),
    ];
  }

  List<String> _blockDelta(JsonValue data) {
    final item = _blocks[data.get('index').integer];
    if (item == null) return const [];
    final delta = data.get('delta');
    switch (delta.get('type').string) {
      case 'text_delta':
        final text = delta.get('text').string;
        return item.kind == 'message' && text.isNotEmpty
            ? _textDelta(item, text)
            : const [];
      case 'thinking_delta':
        final text = delta.get('thinking').string;
        if (item.kind != 'reasoning' || text.isEmpty) return const [];
        item.text.write(text);
        return [
          _event('response.reasoning_summary_text.delta', {
            'item_id': item.id,
            'output_index': item.index,
            'summary_index': 0,
            'delta': text,
          }),
        ];
      case 'signature_delta':
        item.signature += delta.get('signature').string;
        return const [];
      case 'input_json_delta':
        final json = delta.get('partial_json').string;
        if (item.kind != 'function_call' || json.isEmpty) return const [];
        item.text.write(json);
        return [
          _event('response.function_call_arguments.delta', {
            'item_id': item.id,
            'output_index': item.index,
            'delta': json,
          }),
        ];
    }
    return const [];
  }

  List<String> _blockStop(JsonValue data) {
    final item = _blocks.remove(data.get('index').integer);
    return item == null ? const [] : _finish(item);
  }

  /// [item]'s closing events, and the item as it is now done.
  List<String> _finish(_Block item) {
    final text = '${item.text}';
    switch (item.kind) {
      case 'message':
        final part = {
          'type': 'output_text',
          'text': text,
          'annotations': const [],
        };
        final done = {
          'type': 'message',
          'id': item.id,
          'role': 'assistant',
          'status': 'completed',
          'content': [part],
        };
        _done[item.index] = done;
        return [
          _event('response.output_text.done', {
            'item_id': item.id,
            'output_index': item.index,
            'content_index': 0,
            'text': text,
          }),
          _event('response.content_part.done', {
            'item_id': item.id,
            'output_index': item.index,
            'content_index': 0,
            'part': part,
          }),
          _event('response.output_item.done', {
            'output_index': item.index,
            'item': done,
          }),
        ];
      case 'reasoning':
        final done = {
          'type': 'reasoning',
          'id': item.id,
          'summary': [
            if (text.isNotEmpty) {'type': 'summary_text', 'text': text},
          ],
          'encrypted_content': item.signature.isEmpty ? null : item.signature,
        };
        _done[item.index] = done;
        return [
          if (text.isNotEmpty)
            _event('response.reasoning_summary_text.done', {
              'item_id': item.id,
              'output_index': item.index,
              'summary_index': 0,
              'text': text,
            }),
          _event('response.output_item.done', {
            'output_index': item.index,
            'item': done,
          }),
        ];
      default:
        // A call with no arguments says `{}`.
        final arguments = text.trim().isEmpty ? '{}' : text;
        final done = {
          'type': 'function_call',
          'id': item.id,
          'call_id': item.callId,
          'name': item.name,
          'arguments': arguments,
          'status': 'completed',
        };
        _done[item.index] = done;
        return [
          _event('response.function_call_arguments.done', {
            'item_id': item.id,
            'output_index': item.index,
            'arguments': arguments,
          }),
          _event('response.output_item.done', {
            'output_index': item.index,
            'item': done,
          }),
        ];
    }
  }

  List<String> _messageDelta(JsonValue data) {
    if (data.get('delta.stop_reason').string case final reason
        when reason.isNotEmpty) {
      _stopReason = reason;
    }
    _readUsage(data.get('usage'));
    return const [];
  }

  List<String> _messageStop() {
    final events = <String>[];
    // A stream with nothing in it still begins the response.
    if (!_started) {
      _started = true;
      events.add(
        _event('response.created', {'response': _response('in_progress')}),
      );
    }
    // Blocks the stream did not close.
    for (final item
        in _blocks.values.toList()
          ..sort((a, b) => a.index.compareTo(b.index))) {
      events.addAll(_finish(item));
    }
    _blocks.clear();
    _finished = true;
    if (_stopReason == 'max_tokens') {
      events.add(
        _event('response.incomplete', {
          'response': _response(
            'incomplete',
            extra: {
              'incomplete_details': {'reason': 'max_output_tokens'},
              'usage': _usage,
            },
          ),
        }),
      );
    } else {
      events.add(
        _event('response.completed', {
          'response': _response('completed', extra: {'usage': _usage}),
        }),
      );
    }
    return events;
  }

  /// The stream ended without Anthropic's ending it: the failure [message]
  /// says, as an upstream's own error is. None once it finished.
  List<String> abort(String message) {
    if (_finished) return const [];
    final events = <String>[
      if (!_started)
        _event('response.created', {'response': _response('in_progress')}),
    ];
    _started = true;
    _finished = true;
    return [
      ...events,
      _event('response.failed', {
        'response': _response(
          'failed',
          extra: {
            'error': {'code': 'server_error', 'message': message},
          },
        ),
      }),
    ];
  }

  List<String> _error(JsonValue data) {
    _finished = true;
    final error = data.get('error');
    final type = error.get('type').string;
    return [
      _event('response.failed', {
        'response': _response(
          'failed',
          extra: {
            'error': {
              'code': switch (type) {
                'rate_limit_error' => 'rate_limit_exceeded',
                'overloaded_error' => 'server_is_overloaded',
                'invalid_request_error' => 'invalid_prompt',
                '' => 'server_error',
                _ => type,
              },
              'message': error.get('message').string.isNotEmpty
                  ? error.get('message').string
                  : jsonEncode(data.value),
            },
          },
        ),
      }),
    ];
  }
}
