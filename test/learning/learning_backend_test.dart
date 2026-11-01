import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/learning/learning_backend.dart';
import 'package:baocode/learning/learning_controller.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/learning_preferences.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

const provider = ModelProvider(
  id: 'lesson',
  name: 'Synthetic provider',
  baseUrl: 'https://invalid.example',
  models: [
    ProviderModel(id: 'explain-model'),
    ProviderModel(id: 'worker-model'),
  ],
);
const request = LearningRequest(
  evidence: [
    LearningEvidence(
      id: 'e1',
      kind: 'edit',
      label: 'Synthetic change',
      excerpt: 'Added an empty-input check.',
    ),
  ],
  depth: LearningDepth.brief,
);
const reply =
    '{"title":"Guard clauses","summary":"Added a check.","why":"May avoid invalid input.","concept":"Fail early.","evidenceIds":["e1"]}';

void main() {
  late ModelProviders providers;
  late LearningPreferences preferences;
  setUp(() {
    providers = ModelProviders.memory(providers: [provider]);
    preferences = LearningPreferences.memory(providers: providers);
  });
  tearDown(() {
    preferences.dispose();
    providers.dispose();
  });

  Future<void> enable() =>
      preferences.configure(modelRef: '@lesson/explain-model', consent: true);

  test(
    'disabled by default and no transport without explicit consent',
    () async {
      var calls = 0;
      final backend = LearningBackend(
        preferences: preferences,
        transport: (_, _, _, _) async {
          calls++;
          return reply;
        },
      );
      expect(preferences.enabled, isFalse);
      expect(preferences.modelRef, isNull);
      await expectLater(
        backend.generate(request, LearningCancellation()),
        throwsA(isA<LearningBackendException>()),
      );
      await expectLater(
        preferences.configure(
          modelRef: '@lesson/explain-model',
          consent: false,
        ),
        throwsArgumentError,
      );
      expect(calls, 0);
      expect(preferences.enabled, isFalse);
    },
  );

  test(
    'exact independent selection; no fallback to worker or provider main',
    () async {
      await providers.setDefaultModel('@lesson/worker-model');
      await providers.setAuxiliaryModel('@lesson/worker-model');
      await enable();
      final backend = LearningBackend(
        preferences: preferences,
        transport: (p, m, body, _) async {
          expect(p.id, 'lesson');
          expect(m.id, 'explain-model');
          expect(body['model'], 'explain-model');
          expect(body['max_tokens'], 700);
          expect(body.containsKey('tools'), isFalse);
          expect(body.containsKey('tool_choice'), isFalse);
          expect(body.containsKey('thinking'), isFalse);
          expect(jsonEncode(body), isNot(contains('worker-model')));
          expect(jsonEncode(body), contains('untrusted data'));
          return reply;
        },
      );
      expect(
        (await backend.generate(request, LearningCancellation()))['title'],
        'Guard clauses',
      );
      expect(providers.defaultModel, '@lesson/worker-model');
      await expectLater(
        preferences.configure(modelRef: '@lesson/missing', consent: true),
        throwsArgumentError,
      );
      expect(preferences.modelRef, '@lesson/explain-model');
    },
  );

  test(
    'provider changes invalidate consent and do not send to new endpoint',
    () async {
      await enable();
      expect(preferences.enabled, isTrue);
      await providers.save(
        provider.copyWith(baseUrl: 'https://changed.invalid'),
      );
      expect(preferences.enabled, isFalse);
      var calls = 0;
      final backend = LearningBackend(
        preferences: preferences,
        transport: (_, _, _, _) async {
          calls++;
          return reply;
        },
      );
      await expectLater(
        backend.generate(request, LearningCancellation()),
        throwsA(isA<LearningBackendException>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'disabled/missing models excluded, no automatic/builtin choices',
    () async {
      await providers.save(
        provider.copyWith(
          models: [
            const ProviderModel(id: 'explain-model'),
            const ProviderModel(id: 'off', enabled: false),
            const ProviderModel(id: 'gone', missing: true),
          ],
        ),
      );
      expect(LearningBackend.choices(providers).map((choice) => choice.ref), [
        '@lesson/explain-model',
      ]);
      expect(
        LearningBackend.modelLabel('@lesson/explain-model', providers),
        'Synthetic provider · explain-model',
      );
      expect(LearningBackend.modelLabel('@lesson/missing', providers), isNull);
    },
  );

  test(
    'preference writes retain independent depth and pacing updates',
    () async {
      await Future.wait([
        enable(),
        preferences.setDepth(LearningDepth.detailed),
        preferences.setPace(LearningPace.balanced),
      ]);
      expect(preferences.enabled, isTrue);
      expect(preferences.depth, LearningDepth.detailed);
      expect(preferences.interval, const Duration(seconds: 12));
      await preferences.disable();
      expect(preferences.enabled, isFalse);
      expect(preferences.modelRef, '@lesson/explain-model');
    },
  );

  test('disable signals cancellation but retains the slot until transport teardown', () async {
    await enable();
    final pending = Completer<String>();
    final started = Completer<void>();
    LearningCancellation? transportCancellation;
    final backend = LearningBackend(
      preferences: preferences,
      transport: (_, _, _, cancellation) {
        transportCancellation = cancellation;
        started.complete();
        return pending.future;
      },
    );
    var settled = false;
    final result = backend
        .generate(request, LearningCancellation())
        .whenComplete(() {
          settled = true;
        });
    final expectation = expectLater(
      result,
      throwsA(isA<LearningBackendException>()),
    );
    await started.future;
    await preferences.disable();
    await Future<void>.delayed(Duration.zero);
    expect(transportCancellation!.isCancelled, isTrue);
    expect(settled, isFalse);
    pending.complete(reply);
    await expectation;
    expect(settled, isTrue);
  });

  for (final switchModel in [false, true]) {
    test(
      'controller retains actual single flight across ${switchModel ? 'model change' : 'pause/resume'}',
      () async {
        await enable();
        final controller = LearningController();
        final pending = Completer<String>();
        final cancellations = <LearningCancellation>[];
        var active = 0;
        var maximumActive = 0;
        var calls = 0;
        Future<String> transport(
          ModelProvider p,
          ProviderModel m,
          Map<String, Object?> body,
          LearningCancellation cancellation,
        ) async {
          calls++;
          active++;
          if (active > maximumActive) maximumActive = active;
          cancellations.add(cancellation);
          try {
            if (calls == 1) return await pending.future;
            final messages = body['messages'] as List;
            final evidence = jsonDecode(
              (messages.single as Map)['content'] as String,
            ) as Map;
            final id = ((evidence['evidence'] as List).single as Map)['id'];
            return jsonEncode({
              ...jsonDecode(reply) as Map<String, dynamic>,
              'evidenceIds': [id],
            });
          } finally {
            active--;
          }
        }

        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        }

        void observe(int seq) => controller.observe(
          ItemUpserted(
            seq,
            'operation-$seq',
            TerminalItem(
              command: 'flutter test synthetic_$seq.dart',
              output: 'Passed',
            ),
          ),
        );
        controller.enable(
          LearningBackend(preferences: preferences, transport: transport),
          interval: Duration.zero,
        );
        observe(1);
        await settle();
        expect(calls, 1);
        expect(controller.busy, isTrue);
        if (switchModel) {
          await preferences.configure(
            modelRef: '@lesson/worker-model',
            consent: true,
          );
          controller.enable(
            LearningBackend(preferences: preferences, transport: transport),
            interval: Duration.zero,
          );
        } else {
          controller.setPaused(true);
          expect(controller.paused, isTrue);
          controller.setPaused(false);
        }
        observe(2);
        await settle();
        expect(cancellations.first.isCancelled, isTrue);
        expect(controller.busy, isTrue);
        expect(calls, 1, reason: 'Cancellation is not transport completion');
        expect(controller.cards, isEmpty);
        pending.complete(reply);
        await settle();
        expect(calls, 2);
        expect(maximumActive, 1);
        expect(active, 0);
        expect(
          controller.cards,
          hasLength(1),
          reason: 'Only the new request may publish a card',
        );
        expect(
          controller.cards.single.evidence.single.sourceItemId,
          'operation-2',
        );
        controller.dispose();
      },
    );
  }

  test(
    'malformed, huge and raw provider errors never surface raw bodies',
    () async {
      await enable();
      for (final response in ['not JSON secret', '[]', 'x' * 16001]) {
        final backend = LearningBackend(
          preferences: preferences,
          transport: (_, _, _, _) async => response,
        );
        await expectLater(
          backend.generate(request, LearningCancellation()),
          throwsA(
            isA<LearningBackendException>().having(
              (error) => '$error',
              'safe error',
              isNot(contains('secret')),
            ),
          ),
        );
      }
      final backend = LearningBackend(
        preferences: preferences,
        transport: (_, _, _, _) async =>
            throw StateError('secret-api-key private diff'),
      );
      await expectLater(
        backend.generate(request, LearningCancellation()),
        throwsA(
          isA<LearningBackendException>().having(
            (error) => '$error',
            'safe error',
            isNot(contains('secret-api-key')),
          ),
        ),
      );
    },
  );

  test(
    'consent is bound to one project scope, not global model selection',
    () async {
      final values = <String, Object?>{};
      LearningPreferences scoped(String scope) => LearningPreferences(
        read: (key) => values[key],
        write: (key, value) async {
          values[key] = value;
        },
        providers: providers,
        scope: scope,
      );
      final first = scoped('/synthetic/project-a');
      final second = scoped('/synthetic/project-b');
      await first.configure(modelRef: '@lesson/explain-model', consent: true);
      expect(first.enabled, isTrue);
      expect(second.enabled, isFalse);
      expect(second.modelRef, '@lesson/explain-model');
      expect(jsonEncode(values), isNot(contains('/synthetic/project-a')));
      await second.configure(modelRef: '@lesson/explain-model', consent: true);
      expect(first.enabled, isFalse);
      expect(second.enabled, isTrue);
      first.dispose();
      second.dispose();
    },
  );

  test('oversized context rejected before any transport', () async {
    await enable();
    var calls = 0;
    final backend = LearningBackend(
      preferences: preferences,
      transport: (_, _, _, _) async {
        calls++;
        return reply;
      },
    );
    await expectLater(
      backend.generate(
        LearningRequest(
          evidence: [
            LearningEvidence(
              id: 'e',
              kind: 'edit',
              label: 'large',
              excerpt: 'a' * 19000,
            ),
          ],
          depth: LearningDepth.brief,
        ),
        LearningCancellation(),
      ),
      throwsA(isA<LearningBackendException>()),
    );
    expect(calls, 0);
  });
}
