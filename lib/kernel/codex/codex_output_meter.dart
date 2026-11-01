import 'dart:math' as math;

import '../../chat/chat_models.dart';
import '../output_meter.dart';

/// Codex counts output only at request boundaries. Between them, use the
/// same text estimate as the Claude adapter. Reasoning summaries and tool
/// results are not model output and must not be timed as generated tokens.
class CodexOutputMeter {
  CodexOutputMeter({DateTime Function()? clock})
    : _meter = OutputMeter(clock: clock);

  final OutputMeter _meter;
  String? _textId;
  final Set<String> _finished = {};
  int _textLength = 0;
  int? _conversationInput;
  int? _conversationOutput;
  int? _inputBase;
  int? _outputBase;
  int? _input;
  int? _output;
  int _estimatedAtReport = 0;

  void begin() {
    _meter.begin();
    _textId = null;
    _textLength = 0;
    _finished.clear();
    _inputBase = _conversationInput;
    _outputBase = _conversationOutput;
    _input = _output = null;
    _estimatedAtReport = 0;
  }

  void startText(String id) {
    if (_textId == id || _finished.contains(id)) return;
    _finishText();
    _textId = id;
    _textLength = 0;
    _meter.startMessage();
    _meter.startBlock();
  }

  void text(String id, String delta) {
    if (_finished.contains(id) || delta.isEmpty) return;
    startText(id);
    _textLength += delta.length;
    _meter.streamed(delta);
  }

  void endText(String id, String text) {
    if (_finished.contains(id)) return;
    startText(id);
    // Completion can contain text with no observed generation times.
    // Count its unseen tail without timing it: a delayed final snapshot
    // is not evidence that those tokens streamed over the intervening wait.
    if (text.length > _textLength) {
      final before = _meter.output.tokens;
      _meter.streamed(text.substring(_textLength), timed: false);
      // A usage notification may precede this final snapshot. Only live
      // deltas extend an authoritative count; wait for usage to count an
      // unseen completion tail rather than possibly counting it twice.
      if (_output != null) {
        _estimatedAtReport += _meter.output.tokens - before;
      }
    }
    _finishText();
  }

  void _finishText() {
    if (_textId == null) return;
    _finished.add(_textId!);
    _meter.endMessage();
    _textId = null;
    _textLength = 0;
  }

  /// Conversation totals give an idempotent count even if a notification
  /// is repeated. With no earlier total (e.g. a resumed conversation), the
  /// first request's `last` establishes the baseline, not its old history.
  void usage(
    Map<String, Object?> total,
    Map<String, Object?> last, {
    required bool inTurn,
  }) {
    int? count(Map<String, Object?> value, String key) {
      final raw = value[key];
      return raw is num && raw >= 0 ? raw.toInt() : null;
    }

    final input = count(total, 'inputTokens');
    final output = count(total, 'outputTokens');
    if (inTurn) {
      if (input != null) {
        if (_inputBase == null || input < _inputBase!) {
          final recent = count(last, 'inputTokens');
          if (recent != null) _inputBase = math.max(0, input - recent);
        }
        if (_inputBase != null) _input = input - _inputBase!;
      }
      if (output != null) {
        if (_outputBase == null || output < _outputBase!) {
          final recent = count(last, 'outputTokens');
          if (recent != null) _outputBase = math.max(0, output - recent);
        }
        if (_outputBase != null &&
            (_output == null || output != _conversationOutput)) {
          _output = output - _outputBase!;
          _estimatedAtReport = _meter.output.tokens;
        }
      }
    } else {
      // Initial/resume usage is history, even if the UI has already sent
      // the next prompt while the process was still starting.
      _inputBase = input ?? _inputBase;
      _outputBase = output ?? _outputBase;
    }
    _conversationInput = input ?? _conversationInput;
    _conversationOutput = output ?? _conversationOutput;
  }

  TurnOutput get output => TurnOutput(
    tokens: _output == null
        ? _meter.output.tokens
        : _output! + math.max(0, _meter.output.tokens - _estimatedAtReport),
    tokensPerSecond: _meter.output.tokensPerSecond,
  );

  TurnUsage finish() {
    _finishText();
    return TurnUsage(
      inputTokens: _input,
      outputTokens: _output,
      tokensPerSecond: _meter.averageSpeed,
    );
  }
}
