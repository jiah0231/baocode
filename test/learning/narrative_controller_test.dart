import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/learning/learning_controller.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/narrative_models.dart';
import 'package:flutter_test/flutter_test.dart';

const fact = NarrativeFact(
  id: 'f1',
  kind: 'command',
  label: 'Inspect input handling',
  status: 'completed',
  sourceItemId: 'operation-1',
);
NarrativeSnapshot snapshot(
  int revision, {
  List<NarrativeFact> facts = const [fact],
  bool ended = false,
  String turn = 'turn-1',
}) => NarrativeSnapshot(
  turnId: turn,
  revision: revision,
  facts: facts,
  ended: ended,
);
Map<String, Object?> answer(LearningRequest request) =>
    request.kind == LearningRequestKind.narrative
    ? {
        'phases': [
          {
            'id': 'phase-1',
            'title': 'Inspect input handling',
            'summary': 'The inspection operation finished. Its findings are not supplied.',
            'status': 'observed',
            'evidenceIds': [request.narrative!.facts.first.id],
          },
        ],
      }
    : {
        'title': 'Inspection',
        'summary': 'The command finished.',
        'why': 'It may inspect behavior.',
        'concept': 'Completion is not proof of correctness.',
        'evidenceIds': [request.evidence.single.id],
      };

class Generator implements LearningGenerator {
  final requests = <LearningRequest>[];
  final tokens = <LearningCancellation>[];
  Future<Map<String, Object?>> Function(LearningRequest)? respond;
  @override
  Future<Map<String, Object?>> generate(
    LearningRequest request,
    LearningCancellation cancellation,
  ) async {
    requests.add(request);
    tokens.add(cancellation);
    return respond == null ? answer(request) : respond!(request);
  }
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ItemUpserted command(int seq) => ItemUpserted(
  seq,
  'operation-$seq',
  TerminalItem(command: 'inspect file_$seq.dart', output: 'Finished'),
);

void main() {
  test('off and paused never send progress facts', () async {
    final c = LearningController();
    final g = Generator();
    c.submitNarrative(snapshot(1));
    c.enable(g, interval: Duration.zero);
    await settle();
    expect(g.requests, isEmpty);
    c.setPaused(true);
    c.submitNarrative(snapshot(2));
    c.setPaused(false);
    await settle();
    expect(g.requests, isEmpty);
    c.dispose();
  });

  test('narrative and exact bubbles share one flight and alternate', () async {
    final c = LearningController();
    final g = Generator();
    final first = Completer<Map<String, Object?>>();
    g.respond = (_) => first.future;
    c.enable(g, interval: Duration.zero);
    c.observe(command(1));
    c.submitNarrative(snapshot(1));
    await settle();
    expect(g.requests.single.kind, LearningRequestKind.narrative);
    c.submitNarrative(
      snapshot(
        2,
        facts: [
          fact,
          const NarrativeFact(
            id: 'f2',
            kind: 'file',
            label: 'Update parser',
            status: 'completed',
            sourceItemId: 'operation-2',
          ),
        ],
      ),
    );
    await settle();
    expect(g.requests, hasLength(1));
    expect(g.tokens.single.isCancelled, isFalse);
    g.respond = null;
    first.complete(answer(g.requests.first));
    await settle();
    expect(g.requests.map((r) => r.kind), [
      LearningRequestKind.narrative,
      LearningRequestKind.explanation,
      LearningRequestKind.narrative,
    ]);
    expect(c.cardForItem('operation-1'), isNotNull);
    expect(c.narrativePhases, hasLength(1));
    expect(c.narrativeRevision, 2);
    c.dispose();
  });

  test('unknown source and unsupported success status are rejected', () async {
    final c = LearningController();
    final g = Generator();
    c.enable(g, interval: Duration.zero);
    g.respond = (_) async => {
      'phases': [
        {
          'id': 'phase-1',
          'title': 'Invented',
          'summary': 'Unsupported result.',
          'status': 'observed',
          'evidenceIds': ['invented'],
        },
      ],
    };
    c.submitNarrative(snapshot(1));
    await settle();
    expect(c.narrativePhases, isEmpty);
    expect(c.narrativeError, isNotNull);
    g.respond = (_) async => {
      'phases': [
        {
          'id': 'phase-1',
          'title': 'Invented',
          'summary': 'All checks passed.',
          'status': 'observed',
          'evidenceIds': ['f1'],
        },
      ],
    };
    c.submitNarrative(
      snapshot(
        2,
        facts: [
          const NarrativeFact(
            id: 'f1',
            kind: 'command',
            label: 'Check still running',
            status: 'running',
          ),
        ],
      ),
    );
    await settle();
    expect(c.narrativePhases, isEmpty);
    expect(c.narrativeError, isNotNull);
    c.dispose();
  });

  test(
    'transport errors stay generic; valid failed status is grounded',
    () async {
      final c = LearningController();
      final g = Generator();
      c.enable(g, interval: Duration.zero);
      g.respond = (_) async =>
          throw StateError('api_key=private-provider-payload');
      c.submitNarrative(snapshot(1));
      await settle();
      expect(c.narrativeError, isNotNull);
      expect(c.narrativeError, isNot(contains('private-provider-payload')));
      expect(c.narrativePhases, isEmpty);
      g.respond = (_) async => {
        'phases': [
          {
            'id': 'phase-1',
            'title': 'Check failed',
            'summary':
                'The observed command failed. Its cause is not supplied.',
            'status': 'failed',
            'evidenceIds': ['f1'],
          },
        ],
      };
      c.submitNarrative(
        snapshot(
          2,
          facts: [
            const NarrativeFact(
              id: 'f1',
              kind: 'command',
              label: 'Check failed',
              status: 'failed',
              sourceItemId: 'operation-1',
            ),
          ],
        ),
      );
      await settle();
      expect(c.narrativeError, isNull);
      expect(c.narrativePhases.single.status, 'failed');
      c.dispose();
    },
  );

  test(
    'changed source invalidates old response while appended source does not',
    () async {
      final c = LearningController();
      final g = Generator();
      final first = Completer<Map<String, Object?>>();
      final second = Completer<Map<String, Object?>>();
      g.respond = (_) => g.requests.length == 1 ? first.future : second.future;
      c.enable(g, interval: Duration.zero);
      c.submitNarrative(snapshot(1));
      await settle();
      c.submitNarrative(
        snapshot(
          2,
          facts: [
            const NarrativeFact(
              id: 'f1',
              kind: 'command',
              label: 'Inspection failed',
              status: 'failed',
              sourceItemId: 'operation-1',
            ),
          ],
        ),
      );
      first.complete(answer(g.requests.first));
      await settle();
      expect(c.narrativePhases, isEmpty);
      expect(c.narrativeError, isNull);
      c.dispose();
      second.complete(answer(g.requests.last));
      await settle();
    },
  );

  test(
    'source removal purges pending narrative and old turn cannot return',
    () async {
      final c = LearningController();
      final g = Generator();
      final pending = Completer<Map<String, Object?>>();
      g.respond = (_) => pending.future;
      c.enable(g, interval: Duration.zero);
      c.submitNarrative(snapshot(1));
      await settle();
      c.observe(const ItemRemoved(4, 'operation-1'), allowGeneration: false);
      expect(g.tokens.first.isCancelled, isTrue);
      c.submitNarrative(snapshot(1, facts: const [], turn: 'next-turn'));
      pending.complete(answer(g.requests.first));
      await settle();
      expect(c.narrativeTurnId, 'next-turn');
      expect(c.narrativePhases, isEmpty);
      c.dispose();
    },
  );

  test(
    'confirmed diff enriches narrative; preview never does; payload bounded',
    () async {
      final c = LearningController();
      final g = Generator();
      c.enable(g, interval: Duration.zero);
      c.observe(
        const ItemUpserted(
          1,
          'edit-1',
          CodeDiffItem(
            fileName: 'parser.dart',
            directory: 'lib',
            lines: [
              DiffLine(DiffLineType.added, 1, 'if (input.isEmpty) return;'),
            ],
          ),
        ),
      );
      c.submitNarrative(
        snapshot(
          1,
          facts: [
            const NarrativeFact(
              id: 'edit-1',
              sourceItemId: 'edit-1',
              kind: 'file',
              label: 'parser.dart',
              status: 'completed',
            ),
          ],
        ),
      );
      await settle();
      expect(g.requests.first.narrative!.facts.single.excerpt, isNull);
      c.observe(
        const FileEdited(
          2,
          FileChange(path: 'lib/parser.dart', added: 1, removed: 0),
          sourceItemId: 'edit-1',
        ),
      );
      c.submitNarrative(
        snapshot(
          2,
          facts: [
            const NarrativeFact(
              id: 'edit-1',
              sourceItemId: 'edit-1',
              kind: 'file',
              label: 'parser.dart',
              status: 'completed',
            ),
          ],
        ),
      );
      await settle();
      final last = g.requests.lastWhere(
        (r) => r.kind == LearningRequestKind.narrative,
      );
      expect(last.narrative!.facts.single.excerpt, contains('input.isEmpty'));
      for (final request in g.requests.where(
        (r) => r.kind == LearningRequestKind.narrative,
      )) {
        expect(
          jsonEncode(request.toJson()).length,
          lessThanOrEqualTo(LearningController.maxContextCharacters),
        );
      }
      c.dispose();
    },
  );

  test(
    'bubbles reserve progress slots and ongoing narration reserves final slot',
    () async {
      final c = LearningController();
      final g = Generator();
      c.enable(g, interval: Duration.zero);
      for (var i = 1; i <= 24; i++) {
        c.observe(command(i));
        await settle();
      }
      expect(g.requests, hasLength(22));
      c.submitNarrative(snapshot(1));
      await settle();
      expect(g.requests, hasLength(23));
      c.submitNarrative(snapshot(2));
      await settle();
      expect(g.requests, hasLength(23));
      c.submitNarrative(snapshot(3, ended: true));
      await settle();
      expect(g.requests, hasLength(24));
      expect(c.budgetReached, isTrue);
      expect(c.narrativeEnded, isTrue);
      c.dispose();
    },
  );
}
