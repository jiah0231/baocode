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
  for (var i = 0; i < 8; i++) {
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
    'consent-disabled retained card is invalidated by source revision',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      controller.disable(clearCards: false);
      expect(controller.cardForItem('step-1'), isNotNull);
      controller.observe(
        command(1, output: 'Revised while sharing is disabled'),
      );
      await settle();
      expect(controller.cardForItem('step-1'), isNull);
      expect(generator.requests, hasLength(1));
      controller.dispose();
    },
  );

  test(
    'out-of-turn updates invalidate exact bubbles without paid replay',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      controller.observe(command(1));
      await settle();
      controller.observe(
        command(1, output: 'Changed outside turn'),
        allowGeneration: false,
      );
      controller.observe(command(2), allowGeneration: false);
      await settle();
      expect(controller.cards, isEmpty);
      expect(generator.requests, hasLength(1));
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
    'paces separate anchored operations and deduplicates repeated events',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      for (var i = 1; i <= 4; i++) {
        controller.observe(command(i));
      }
      controller.observe(command(1));
      await settle();
      expect(generator.requests.length, 4);
      expect(generator.requests.every((r) => r.evidence.length == 1), isTrue);
      expect(controller.cards.length, 4);
      expect(controller.cardForItem('step-2')!.sourceItemId, 'step-2');
      expect(controller.cardForItem('missing'), isNull);
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

  test('provisional diff never sends before a confirmed file edit', () async {
    final controller = LearningController();
    final generator = FakeGenerator();
    controller.enable(generator, interval: Duration.zero);
    const preview = CodeDiffItem(
      fileName: 'main.dart',
      directory: 'lib',
      lines: [DiffLine(DiffLineType.added, 1, 'final answer = 42;')],
    );
    controller.observe(const ItemUpserted(1, 'preview', preview));
    controller.observe(const ItemCompleted(2, 'preview', item: preview));
    await settle();
    expect(generator.requests, isEmpty);
    expect(controller.queuedCount, 0);
    controller.observe(
      const FileEdited(
        3,
        FileChange(path: 'lib/main.dart', added: 1, removed: 0),
        sourceItemId: 'preview',
      ),
    );
    await settle();
    expect(generator.requests.single.evidence.single.kind, 'diff');
    expect(
      generator.requests.single.evidence.single.excerpt,
      contains('answer = 42'),
    );
    controller.dispose();
  });

  test(
    'denied preview is discarded and cannot attach to a later edit',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      controller.observe(
        const ItemUpserted(
          1,
          'preview',
          CodeDiffItem(
            fileName: 'main.dart',
            directory: 'lib',
            lines: [DiffLine(DiffLineType.added, 1, 'unapproved code')],
          ),
        ),
      );
      controller.observe(
        const ItemUpserted(
          2,
          'preview',
          ToolCallItem(
            kind: ToolKind.edit,
            target: 'lib/main.dart',
            status: ToolStatus.denied,
          ),
        ),
      );
      await settle();
      expect(generator.requests, isEmpty);
      controller.observe(
        const FileEdited(
          3,
          FileChange(path: 'lib/main.dart', added: 1, removed: 0),
          sourceItemId: 'later-operation',
        ),
      );
      await settle();
      expect(generator.requests.single.evidence.single.kind, 'file-summary');
      expect(
        generator.requests.single.evidence.single.excerpt,
        isNot(contains('unapproved code')),
      );
      controller.dispose();
    },
  );

  test(
    'staged previews expire on pause, turn end and bounded eviction',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      for (var i = 0; i < 20; i++) {
        controller.observe(
          ItemUpserted(
            i + 1,
            'preview-$i',
            CodeDiffItem(
              fileName: 'file$i.dart',
              directory: 'lib',
              lines: [DiffLine(DiffLineType.added, 1, 'changed $i')],
            ),
          ),
        );
      }
      controller.observe(
        const FileEdited(
          21,
          FileChange(path: 'lib/file0.dart', added: 1, removed: 0),
          sourceItemId: 'preview-0',
        ),
      );
      await settle();
      expect(generator.requests.last.evidence.single.kind, 'file-summary');
      controller.observe(const TurnEnded(22, 'turn'));
      controller.observe(
        const FileEdited(
          23,
          FileChange(path: 'lib/file19.dart', added: 2, removed: 0),
          sourceItemId: 'preview-19',
        ),
      );
      await settle();
      expect(generator.requests.last.evidence.single.kind, 'file-summary');
      controller.observe(
        const ItemUpserted(
          24,
          'paused-preview',
          CodeDiffItem(
            fileName: 'paused.dart',
            directory: 'lib',
            lines: [DiffLine(DiffLineType.added, 1, 'pending')],
          ),
        ),
      );
      controller.setPaused(true);
      controller.setPaused(false);
      controller.observe(
        const FileEdited(
          25,
          FileChange(path: 'lib/paused.dart', added: 3, removed: 0),
          sourceItemId: 'paused-preview',
        ),
      );
      await settle();
      expect(generator.requests.last.evidence.single.kind, 'file-summary');
      controller.dispose();
    },
  );

  test(
    'staged preview memory is bounded by context size as well as count',
    () async {
      final controller = LearningController();
      final generator = FakeGenerator();
      controller.enable(generator, interval: Duration.zero);
      for (var i = 0; i < 4; i++) {
        controller.observe(
          ItemUpserted(
            i + 1,
            'large-$i',
            CodeDiffItem(
              fileName: 'large$i.dart',
              directory: 'lib',
              lines: List.generate(
                20,
                (line) => DiffLine(DiffLineType.added, line, 'x' * 200),
              ),
            ),
          ),
        );
      }
      controller.observe(
        const FileEdited(
          5,
          FileChange(path: 'lib/large0.dart', added: 20, removed: 0),
          sourceItemId: 'large-0',
        ),
      );
      controller.observe(
        const FileEdited(
          6,
          FileChange(path: 'lib/large3.dart', added: 20, removed: 0),
          sourceItemId: 'large-3',
        ),
      );
      await settle();
      expect(generator.requests.length, 2);
      expect(generator.requests.first.evidence.single.kind, 'file-summary');
      expect(generator.requests.last.evidence.single.kind, 'diff');
      controller.dispose();
    },
  );

  test('same filename never correlates different operations', () async {
    final controller = LearningController();
    final generator = FakeGenerator();
    controller.enable(generator, interval: Duration.zero);
    controller.observe(
      const ItemUpserted(
        1,
        'preview-a',
        CodeDiffItem(
          fileName: 'main.dart',
          directory: 'lib',
          lines: [DiffLine(DiffLineType.added, 1, 'not operation b')],
        ),
      ),
    );
    controller.observe(
      const FileEdited(
        2,
        FileChange(path: 'lib/main.dart', added: 1, removed: 0),
      ),
    );
    await settle();
    expect(generator.requests, isEmpty);
    controller.observe(
      const FileEdited(
        3,
        FileChange(path: 'lib/main.dart', added: 1, removed: 0),
        sourceItemId: 'operation-b',
      ),
    );
    await settle();
    expect(controller.cardForItem('preview-a'), isNull);
    expect(
      controller.cardForItem('operation-b')!.evidence.single.kind,
      'file-summary',
    );
    expect(
      generator.requests.single.evidence.single.excerpt,
      isNot(contains('not operation b')),
    );
    controller.dispose();
  });

  test('revised operation discards in-flight old explanation', () async {
    final controller = LearningController();
    final generator = FakeGenerator()
      ..pending = Completer<Map<String, Object?>>();
    controller.enable(generator, interval: Duration.zero);
    controller.observe(command(1));
    await settle();
    expect(controller.busyItemId, 'step-1');
    controller.observe(command(1, output: 'A different observed result'));
    expect(generator.cancellations.first.isCancelled, isTrue);
    generator.pending!.complete(valid(generator.requests.first));
    generator.pending = null;
    await settle();
    expect(controller.cards, hasLength(1));
    expect(
      controller.cardForItem('step-1')!.evidence.single.excerpt,
      contains('different observed result'),
    );
    expect(controller.busyItemId, isNull);
    controller.observe(const ItemRemoved(3, 'step-1'));
    expect(controller.cardForItem('step-1'), isNull);
    controller.dispose();
  });

  test('same-path revised previews retain only their exact own code', () async {
    final controller = LearningController();
    final generator = FakeGenerator();
    controller.enable(generator, interval: Duration.zero);
    for (final id in ['first', 'second']) {
      controller.observe(
        ItemUpserted(
          1,
          id,
          CodeDiffItem(
            fileName: 'main.dart',
            directory: 'lib',
            lines: [DiffLine(DiffLineType.added, 1, 'code for $id')],
          ),
        ),
      );
    }
    controller.observe(
      const FileEdited(
        2,
        FileChange(path: 'lib/main.dart', added: 1, removed: 0),
        sourceItemId: 'first',
      ),
    );
    controller.observe(
      const FileEdited(
        3,
        FileChange(path: 'lib/main.dart', added: 1, removed: 0),
        sourceItemId: 'second',
      ),
    );
    await settle();
    expect(generator.requests, hasLength(2));
    expect(
      controller.cardForItem('first')!.evidence.single.excerpt,
      contains('code for first'),
    );
    expect(
      controller.cardForItem('second')!.evidence.single.excerpt,
      contains('code for second'),
    );
    controller.dispose();
  });

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
    controller.observe(
      const FileEdited(3, FileChange(path: '.env.local', added: 1, removed: 0)),
    );
    controller.observe(
      const FileEdited(
        4,
        FileChange(path: 'lib/main.dart', added: 10000, removed: 0),
        sourceItemId: 'code',
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
