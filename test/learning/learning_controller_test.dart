import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/learning/learning_controller.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> valid(LearningRequest request) => {
  'title': 'Small, focused change',
  'summary': 'The observed command finished.',
  'why': 'It may check the code; intent is not known.',
  'concept': 'Verification provides evidence, not a proof of every behavior.',
  'evidenceIds': [request.evidence.first.id],
};

class FakeGenerator implements LearningGenerator {
  final requests = <LearningRequest>[];
  final cancellations = <LearningCancellation>[];
  Completer<Map<String, Object?>>? pending;
  Map<String, Object?> Function(LearningRequest)? response;
  @override
  Future<Map<String, Object?>> generate(
    LearningRequest request,
    LearningCancellation cancellation,
  ) async {
    requests.add(request);
    cancellations.add(cancellation);
    return pending != null ? pending!.future : (response ?? valid)(request);
  }
}

ItemUpserted command(int seq, {String output = 'All checks passed'}) =>
    ItemUpserted(
      seq,
      'step-$seq',
      TerminalItem(command: 'flutter test check_$seq.dart', output: output),
    );
Future<void> settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'completed failures teach explicit failure, not success or denied tools',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      controller.observe(
        const ItemUpserted(
          1,
          'failed-build',
          TerminalItem(
            command: 'flutter build windows',
            output: 'Compilation failed: missing symbol',
            status: CommandStatus.failed,
          ),
        ),
      );
      await settle();
      expect(
        generator.requests.single.evidence.single.excerpt,
        contains('Observed status: failed'),
      );
      expect(
        generator.requests.single.evidence.single.excerpt,
        contains('missing symbol'),
      );
      controller.dispose();
    },
  );

  test(
    'consent invalidation retains session cards; explicit off clears',
    () async {
      final controller = LearningController();
      controller.enable(FakeGenerator(), interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      expect(controller.cards, hasLength(1));
      controller.disable(clearCards: false);
      expect(controller.enabled, isFalse);
      expect(controller.cards, hasLength(1));
      controller.disable();
      expect(controller.cards, isEmpty);
      controller.dispose();
    },
  );

  test(
    'Chinese UI requests Chinese explanations even for English code',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, languageCode: 'zh', interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      expect(
        generator.requests.single.systemInstruction,
        contains('Respond in concise Simplified Chinese'),
      );
      expect(
        generator.requests.single.evidence.first.excerpt,
        contains('flutter test'),
      );
      controller.dispose();
    },
  );

  test(
    'off by default; no transcript thoughts, denied tools or running steps',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.observe(command(1));
      expect(controller.queuedCount, 0);
      controller.enable(generator, interval: Duration.zero);
      controller.observe(
        const ItemUpserted(
          2,
          'thought',
          ThinkingItem(text: 'private reasoning', tokens: 8),
        ),
      );
      controller.observe(
        const ItemUpserted(
          3,
          'denied',
          ToolCallItem(
            kind: ToolKind.command,
            target: 'secret',
            status: ToolStatus.denied,
          ),
        ),
      );
      controller.observe(
        const ItemUpserted(
          4,
          'running',
          TerminalItem(
            command: 'wait',
            output: 'partial',
            status: CommandStatus.running,
          ),
        ),
      );
      await settle();
      expect(generator.requests, isEmpty);
      controller.dispose();
    },
  );

  test(
    'coalesces and deduplicates completed operations with bounded evidence',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      for (var i = 1; i <= 4; i++) {
        controller.observe(command(i));
      }
      controller.observe(command(1));
      await settle();
      expect(generator.requests.length, 2);
      expect(generator.requests.first.evidence.length, 3);
      expect(controller.cards.length, 2);
      expect(controller.cards.first.evidence.first.sourceItemId, 'step-1');
      expect(generator.requests.first.systemInstruction, contains('untrusted'));
      controller.dispose();
    },
  );

  test(
    'pause cancels and drops stale response without overlapping requests',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator()
        ..pending = Completer<Map<String, Object?>>();
      controller.enable(generator, interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      controller.setPaused(true);
      expect(generator.cancellations.single.isCancelled, isTrue);
      controller.observe(command(2));
      controller.setPaused(false);
      controller.observe(command(3));
      await settle();
      expect(generator.requests.length, 1);
      generator.pending!.complete(valid(generator.requests.first));
      generator.pending = null;
      await settle();
      expect(controller.cards.length, 1);
      expect(controller.cards.single.evidence.single.sourceItemId, 'step-3');
      controller.dispose();
    },
  );

  test(
    'switching tasks and disabling discard pending private content',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator()
        ..pending = Completer<Map<String, Object?>>();
      controller.enable(generator, interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      controller.switchSession('other');
      generator.pending!.complete(valid(generator.requests.first));
      await settle();
      expect(controller.cards, isEmpty);
      controller.disable();
      expect(controller.enabled, isFalse);
      expect(controller.queuedCount, 0);
      controller.dispose();
    },
  );

  test(
    'does not accept invented references or leak transport errors',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator()
        ..response = (request) => {
          ...valid(request),
          'evidenceIds': ['invented/path'],
        };
      controller.enable(generator, interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      expect(controller.cards, isEmpty);
      expect(controller.error, isNotNull);
      expect(controller.error, isNot(contains('invented/path')));
      controller.dispose();
    },
  );

  test(
    'redacts known tokens, assignments, URL credentials and private keys',
    () {
      final redacted = redactLearningText(
        'api_key="sk-abcdefghijklm" password=hunter2 Authorization: Bearer abc.def https://user:pass@example.com\n-----BEGIN PRIVATE KEY-----\nsecret material',
      );
      for (final secret in [
        'sk-abcdefghijklm',
        'hunter2',
        'abc.def',
        'user:pass',
        'secret material',
      ]) {
        expect(redacted, isNot(contains(secret)));
      }
    },
  );

  test('excludes sensitive paths and bounds selected code context', () async {
    final controller = LearningController();
    final generator = FakeGenerator();
    controller.enable(generator, interval: Duration.zero);
    controller.observe(
      const ItemUpserted(
        1,
        'env',
        CodeDiffItem(
          fileName: '.env.local',
          directory: '',
          lines: [DiffLine(DiffLineType.added, 1, 'key=secret')],
        ),
      ),
    );
    controller.observe(
      ItemUpserted(
        2,
        'code',
        CodeDiffItem(
          fileName: 'main.dart',
          directory: 'lib',
          lines: List.generate(
            10000,
            (i) => DiffLine(DiffLineType.added, i, 'x' * 1000),
          ),
        ),
      ),
    );
    await settle();
    expect(generator.requests.length, 1);
    final evidence = generator.requests.single.evidence.single;
    expect(evidence.id, 'code');
    expect(evidence.excerpt.length, lessThan(2700));
    controller.dispose();
  });

  test(
    'inactive task drops evidence without changing explicit pause',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      controller.setPaused(true);
      controller.setActive(false);
      controller.setActive(true);
      expect(controller.paused, isTrue);
      controller.observe(command(1));
      await settle();
      expect(generator.requests, isEmpty);
      controller.setPaused(false);
      controller.setActive(false);
      controller.observe(command(2));
      controller.setActive(true);
      await settle();
      expect(generator.requests, isEmpty);
      controller.dispose();
    },
  );

  test(
    'environment dumps and sensitive path commands never leave device',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      var seq = 0;
      for (final cmd in [
        'cat .env.local',
        'printenv',
        'env',
        'cat ~/.ssh/id_rsa',
        'type credentials.json',
      ]) {
        controller.observe(
          ItemUpserted(
            ++seq,
            's-$seq',
            TerminalItem(command: cmd, output: 'unlabelled private data'),
          ),
        );
      }
      await settle();
      expect(generator.requests, isEmpty);
      controller.dispose();
    },
  );

  test('session request and pending queue budgets are hard bounds', () async {
    final controller = LearningController();
    final generator = FakeGenerator();
    controller.enable(generator, interval: Duration.zero);
    for (var i = 0; i < 30; i++) {
      controller.observe(command(i));
      await settle();
    }
    expect(generator.requests.length, LearningController.maxRequestsPerSession);
    expect(controller.budgetReached, isTrue);
    controller.switchSession('next');
    controller.enable(generator, interval: const Duration(days: 1));
    for (var i = 0; i < 100; i++) {
      controller.observe(command(i));
    }
    expect(controller.queuedCount, LearningController.maxQueue);
    controller.dispose();
  });
}
