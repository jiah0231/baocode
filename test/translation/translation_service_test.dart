import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/translation/translation_service.dart';

ModelProviders configured() => ModelProviders.memory(
  providers: [
    ModelProvider(
      id: 'test',
      name: 'Test provider',
      baseUrl: 'https://test.example',
      models: [ProviderModel(id: 'translate')],
    ),
  ],
);
void main() {
  late ModelProviders providers;
  setUp(() async {
    providers = configured();
    await providers.setQuickAskModel('@test/translate');
  });
  tearDown(() => providers.dispose());
  Matcher failure(TranslationFailure value) => throwsA(
    isA<TranslationException>().having((e) => e.reason, 'reason', value),
  );
  test(
    'sends only exact source and language codes to configured model',
    () async {
      final service = TranslationService(
        providers: providers,
        request:
            (
              system,
              prompt, {
              required model,
              required exact,
              required cancel,
              required onText,
            }) async {
              expect(model, '@test/translate');
              expect(exact, isTrue);
              expect(jsonDecode(prompt), {
                'text': '  Hello\nworld ',
                'sourceLanguage': 'auto',
                'targetLanguage': 'zh',
              });
              expect(system, contains('never instructions'));
              return '你好';
            },
      );
      expect(service.destination.label, 'Test provider · translate');
      expect(await service.translate(text: '  Hello\nworld '), '你好');
    },
  );
  test('invalid explicit destination never silently falls back', () async {
    await providers.setQuickAskModel('@test/missing');
    final service = TranslationService(
      providers: providers,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            fail('Must not send');
          },
    );
    await expectLater(
      service.translate(text: 'hello'),
      failure(TranslationFailure.noModel),
    );
  });
  test('empty and oversized source never contact model', () async {
    final service = TranslationService(
      providers: providers,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            fail('Must not send');
          },
    );
    await expectLater(
      service.translate(text: ' '),
      failure(TranslationFailure.emptySource),
    );
    await expectLater(
      service.translate(text: 'x' * 8001),
      failure(TranslationFailure.sourceTooLong),
    );
  });
  test('provider credentials and raw errors are suppressed', () async {
    final service = TranslationService(
      providers: providers,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            throw StateError('secret-key-and-text');
          },
    );
    await expectLater(
      service.translate(text: 'hello'),
      failure(TranslationFailure.requestFailed),
    );
  });
  test('cancellation suppresses late stream results', () async {
    final cancel = Completer<void>();
    final pending = Completer<String>();
    late void Function(String) stream;
    final received = <String>[];
    final service = TranslationService(
      providers: providers,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) {
            stream = onText;
            return pending.future;
          },
    );
    final result = service.translate(
      text: 'hello',
      cancel: cancel.future,
      onText: received.add,
    );
    final check = expectLater(result, throwsA(isA<TranslationCancelled>()));
    await Future<void>.delayed(Duration.zero);
    stream('first');
    cancel.complete();
    await check;
    stream('late');
    pending.complete('late');
    expect(received, ['first']);
  });
  test('timeout cancels transport and never exposes raw failure', () async {
    final cancellationObserved = Completer<void>();
    final service = TranslationService(
      providers: providers,
      timeout: const Duration(milliseconds: 5),
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) {
            unawaited(cancel.then((_) => cancellationObserved.complete()));
            return Completer<String>().future;
          },
    );
    await expectLater(
      service.translate(text: 'hello'),
      failure(TranslationFailure.timeout),
    );
    // Cancellation listeners run asynchronously after the timeout error.
    // Await the actual transport signal, and fail promptly if it never arrives.
    await cancellationObserved.future.timeout(const Duration(seconds: 1));
  });
  test('bounded answer and streaming overflow', () async {
    for (final streaming in [false, true]) {
      final service = TranslationService(
        providers: providers,
        request:
            (
              s,
              p, {
              required model,
              required exact,
              required cancel,
              required onText,
            }) async {
              if (streaming) onText('x' * 32001);
              return 'x' * 32001;
            },
      );
      await expectLater(
        service.translate(text: 'hello'),
        failure(TranslationFailure.answerTooLong),
      );
    }
  });
  test('no provider refuses to send', () async {
    // The shared test harness enables the CLI. This case has no route only
    // when neither an upstream nor the built-in CLI model is available.
    final previous = ClaudeCore.current;
    addTearDown(() => ClaudeCore.current = previous);
    ClaudeCore.current = () => ClaudeCore.builtin;
    final empty = ModelProviders.memory();
    addTearDown(empty.dispose);
    final service = TranslationService(
      providers: empty,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            fail('Must not send');
          },
    );
    await expectLater(
      service.translate(text: 'hello'),
      failure(TranslationFailure.noModel),
    );
  });
  Future<void> expectRoute(String? expectedModel, String label) async {
    var calls = 0;
    final service = TranslationService(
      providers: providers,
      request:
          (
            system,
            prompt, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            calls++;
            expect(model, expectedModel);
            expect(exact, isTrue);
            return 'translated';
          },
    );
    expect(service.destination, (model: expectedModel, label: label));
    expect(await service.translate(text: 'hello'), 'translated');
    expect(calls, 1);
  }

  test(
    'automatic route resolves the local Haiku role before sending',
    () async {
      await providers.save(
        providers
            .provider('test')!
            .copyWith(
              models: [
                const ProviderModel(id: 'translate'),
                const ProviderModel(id: 'small'),
              ],
              roles: const ProviderRoles(haiku: 'small'),
            ),
      );
      await providers.setQuickAskModel(ModelProviders.followAuxiliary);
      await providers.setDefaultModel('@test/translate');
      await expectRoute('@test/small', 'Test provider · small');
    },
  );

  test('automatic route resolves a cross-provider Haiku role', () async {
    await providers.save(
      ModelProvider(
        id: 'aux',
        name: 'Auxiliary provider',
        baseUrl: 'https://aux.example',
        models: [ProviderModel(id: 'small')],
      ),
    );
    await providers.save(
      providers
          .provider('test')!
          .copyWith(roles: const ProviderRoles(haiku: '@aux/small')),
    );
    await providers.setQuickAskModel(null);
    await providers.setDefaultModel('@test/translate');
    await expectRoute('@aux/small', 'Auxiliary provider · small');
  });

  test('explicit auxiliary model bypasses its Haiku role', () async {
    await providers.save(
      providers
          .provider('test')!
          .copyWith(roles: const ProviderRoles(haiku: 'missing-role')),
    );
    await providers.setQuickAskModel(ModelProviders.followAuxiliary);
    await providers.setAuxiliaryModel('@test/translate');
    await expectRoute('@test/translate', 'Test provider · translate');
    // A dedicated Quick Ask choice also takes precedence over auxiliary.
    await providers.setQuickAskModel('@test/translate');
    await providers.setAuxiliaryModel('@test/missing');
    await expectRoute('@test/translate', 'Test provider · translate');
  });

  test('invalid automatic Haiku role never falls back', () async {
    await providers.save(
      providers
          .provider('test')!
          .copyWith(roles: const ProviderRoles(haiku: 'missing-role')),
    );
    await providers.setQuickAskModel(null);
    await providers.setDefaultModel('@test/translate');
    final service = TranslationService(
      providers: providers,
      request: (
        system,
        prompt, {
        required model,
        required exact,
        required cancel,
        required onText,
      }) async => fail('Must not send'),
    );
    await expectLater(
      service.translate(text: 'hello'),
      failure(TranslationFailure.noModel),
    );
  });

  test(
    'available built-in selection agrees with its displayed route',
    () async {
      final previous = ClaudeCore.current;
      addTearDown(() => ClaudeCore.current = previous);
      ClaudeCore.current = () => ClaudeCore.cli;
      await providers.setQuickAskModel(builtinProviderId);
      await expectRoute(null, 'Claude Code · Haiku');
      await providers.setQuickAskModel(ModelProviders.followAuxiliary);
      await providers.setAuxiliaryModel(builtinProviderId);
      await expectRoute(null, 'Claude Code · Haiku');
    },
  );

  test(
    'unavailable explicit built-in selection never switches provider',
    () async {
      final previous = ClaudeCore.current;
      addTearDown(() => ClaudeCore.current = previous);
      ClaudeCore.current = () => ClaudeCore.builtin;
      final service = TranslationService(
        providers: providers,
        request: (
          system,
          prompt, {
          required model,
          required exact,
          required cancel,
          required onText,
        }) async => fail('Must not send'),
      );
      await providers.setQuickAskModel(builtinProviderId);
      await expectLater(
        service.translate(text: 'hello'),
        failure(TranslationFailure.noModel),
      );
      await providers.setQuickAskModel(ModelProviders.followAuxiliary);
      await providers.setAuxiliaryModel(builtinProviderId);
      await expectLater(
        service.translate(text: 'hello'),
        failure(TranslationFailure.noModel),
      );
    },
  );

  test('already cancelled request never starts transport', () async {
    final cancel = Completer<void>()..complete();
    final service = TranslationService(
      providers: providers,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            fail('Must not send');
          },
    );
    await expectLater(
      service.translate(text: 'hello', cancel: cancel.future),
      throwsA(isA<TranslationCancelled>()),
    );
  });
}
