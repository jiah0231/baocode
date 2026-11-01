import 'package:baocode/kernel/codex/codex_output_meter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late CodexOutputMeter meter;

  setUp(() {
    now = DateTime(2026);
    meter = CodexOutputMeter(clock: () => now)..begin();
  });

  void after(int ms) => now = now.add(Duration(milliseconds: ms));

  test('times streamed text, not the waits between messages', () {
    for (var message = 0; message < 4; message++) {
      meter.startText('$message');
      for (var chunk = 0; chunk < 5; chunk++) {
        after(100);
        meter.text('$message', 'a' * 30);
      }
      meter.endText('$message', 'a' * 150);
      after(5000);
    }
    expect(meter.output.tokens, 200);
    expect(meter.output.tokensPerSecond, closeTo(100, 1e-6));
    expect(meter.finish().tokensPerSecond, closeTo(100, 1e-6));
  });

  test('completed text and repeated completion are not counted twice', () {
    meter.text('a', 'a' * 30);
    meter.endText('a', 'a' * 60);
    meter.endText('a', 'a' * 60);
    meter.text('a', 'late');
    expect(meter.output.tokens, 20);
    expect(meter.output.tokensPerSecond, isNull);
  });

  test('a complete nonstreaming message has a count but no fake speed', () {
    after(5000);
    meter.endText('a', 'a' * 300);
    expect(meter.output.tokens, 100);
    expect(meter.output.tokensPerSecond, isNull);
  });

  test('start then delayed completion does not invent a streaming rate', () {
    meter.startText('a');
    after(5000);
    meter.endText('a', 'a' * 300);
    expect(meter.output.tokens, 100);
    expect(meter.output.tokensPerSecond, isNull);
    expect(meter.finish().tokensPerSecond, isNull);
  });

  test('an unseen completion tail does not time the wait after deltas', () {
    meter.startText('a');
    for (var chunk = 0; chunk < 20; chunk++) {
      after(100);
      meter.text('a', 'a' * 30);
    }
    expect(meter.output.tokensPerSecond, closeTo(100, 1e-6));
    after(5000);
    meter.endText('a', 'a' * 3600);
    expect(meter.output.tokens, 1200);
    expect(meter.output.tokensPerSecond, closeTo(100, 1e-6));
    expect(meter.finish().tokensPerSecond, closeTo(100, 1e-6));
  });

  test('usage before a completion snapshot is not counted twice', () {
    meter.startText('a');
    meter.usage({'outputTokens': 100}, {'outputTokens': 100}, inTurn: true);
    after(5000);
    meter.endText('a', 'a' * 300);
    expect(meter.output.tokens, 100);
    expect(meter.finish().outputTokens, 100);
  });

  test('first resumed request excludes the conversation history', () {
    meter.usage(
      {'inputTokens': 11000, 'outputTokens': 10300},
      {'inputTokens': 1000, 'outputTokens': 300},
      inTurn: true,
    );
    expect(meter.output.tokens, 300);
    final usage = meter.finish();
    expect(usage.inputTokens, 1000);
    expect(usage.outputTokens, 300);
  });

  test('counts are cumulative, repeated usage does not erase new deltas', () {
    final total = {'inputTokens': 500, 'outputTokens': 30};
    meter.text('a', 'a' * 30);
    meter.usage(total, total, inTurn: true);
    meter.text('a', 'a' * 30);
    meter.usage(total, total, inTurn: true);
    expect(meter.output.tokens, 40);
    meter.usage(
      {'inputTokens': 900, 'outputTokens': 80},
      {'inputTokens': 400, 'outputTokens': 50},
      inTurn: true,
    );
    expect(meter.output.tokens, 80);
    final usage = meter.finish();
    expect(usage.inputTokens, 900);
    expect(usage.outputTokens, 80);
  });

  test('next turn starts fresh with a known conversation baseline', () {
    meter.usage(
      {'inputTokens': 1000, 'outputTokens': 300},
      {'inputTokens': 1000, 'outputTokens': 300},
      inTurn: true,
    );
    meter.finish();
    meter.begin();
    expect(meter.output.tokens, 0);
    expect(meter.output.tokensPerSecond, isNull);
    meter.usage(
      {'inputTokens': 1600, 'outputTokens': 390},
      {'inputTokens': 600, 'outputTokens': 90},
      inTurn: true,
    );
    final usage = meter.finish();
    expect(usage.inputTokens, 600);
    expect(usage.outputTokens, 90);
  });

  test('initial history report is a baseline, not current output', () {
    meter.usage(
      {'inputTokens': 10000, 'outputTokens': 5000},
      {'inputTokens': 1000, 'outputTokens': 500},
      inTurn: false,
    );
    expect(meter.output.tokens, 0);
    meter.usage(
      {'inputTokens': 12000, 'outputTokens': 5300},
      {'inputTokens': 2000, 'outputTokens': 300},
      inTurn: true,
    );
    expect(meter.finish().outputTokens, 300);
  });

  test('a server counter reset rebases without negative token counts', () {
    meter.usage({'outputTokens': 5000}, {}, inTurn: false);
    meter.usage({'outputTokens': 30}, {'outputTokens': 30}, inTurn: true);
    expect(meter.finish().outputTokens, 30);
  });

  test('missing output usage is not presented as an exact token count', () {
    meter.text('a', 'a' * 30);
    meter.usage({'totalTokens': 100}, {'totalTokens': 100}, inTurn: true);
    expect(meter.output.tokens, 10);
    expect(meter.finish().outputTokens, isNull);
  });
}
