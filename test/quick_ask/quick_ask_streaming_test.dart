import 'dart:async';

import 'package:baocode/kernel/claude_code/claude_haiku.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ModelProviders providers;
  late Completer<String> result;
  late void Function(String) emit;
  late Future<void> transportCancel;
  late QuickAskService service;
  setUp(() {
    providers = ModelProviders.memory(
      providers: [
        ModelProvider(
          id: 'p',
          name: 'P',
          baseUrl: 'https://example.com',
          models: [ProviderModel(id: 'm')],
        ),
      ],
    );
    result = Completer<String>();
    service = QuickAskService(
      providers: providers,
      streamRequest:
          (system, prompt, {model, required exact, cancel, required onText}) {
            emit = onText;
            transportCancel = cancel!;
            return result.future;
          },
    );
  });
  tearDown(() => providers.dispose());

  test('delivers cumulative real chunks before request completes', () async {
    final chunks = <String>[];
    final answer = service.ask(question: 'why', onText: chunks.add);
    await Future<void>.delayed(Duration.zero);
    emit('你');
    emit('你好');
    expect(chunks, ['你', '你好']);
    expect(result.isCompleted, isFalse);
    result.complete('你好');
    expect(await answer, '你好');
    emit('late');
    expect(chunks, ['你', '你好']);
  });

  test('cancel propagates and suppresses late deltas', () async {
    final cancel = Completer<void>();
    final chunks = <String>[];
    final answer = service.ask(
      question: 'why',
      cancel: cancel.future,
      onText: chunks.add,
    );
    final assertion = expectLater(answer, throwsA(isA<ClaudeHaikuCancelled>()));
    await Future<void>.delayed(Duration.zero);
    emit('first');
    cancel.complete();
    await transportCancel;
    emit('late');
    await assertion;
    result.complete('late');
    expect(chunks, ['first']);
  });

  test('stream limit aborts before oversized text reaches UI', () async {
    final chunks = <String>[];
    final answer = service.ask(question: 'why', onText: chunks.add);
    final assertion = expectLater(
      answer,
      throwsA(
        isA<QuickAskException>().having(
          (e) => e.reason,
          'reason',
          QuickAskFailure.answerTooLong,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    emit('x' * (quickAskAnswerLimit + 1));
    await assertion;
    await transportCancel;
    result.complete('ignored');
    expect(chunks, isEmpty);
  });

  test(
    'partial answer is not success when upstream fails; error is safe',
    () async {
      final chunks = <String>[];
      final answer = service.ask(question: 'why', onText: chunks.add);
      final assertion = expectLater(
        answer,
        throwsA(
          isA<QuickAskException>().having(
            (e) => e.reason,
            'reason',
            QuickAskFailure.requestFailed,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      emit('partial');
      result.completeError(Exception('secret-token and private prompt'));
      await assertion;
      emit('late');
      expect(chunks, ['partial']);
    },
  );
  test('timeout aborts a stalled stream and rejects late text', () async {
    final chunks = <String>[];
    service = QuickAskService(
      providers: providers,
      timeout: const Duration(milliseconds: 30),
      streamRequest:
          (system, prompt, {model, required exact, cancel, required onText}) {
            emit = onText;
            transportCancel = cancel!;
            return result.future;
          },
    );
    final answer = service.ask(question: 'why', onText: chunks.add);
    final assertion = expectLater(
      answer,
      throwsA(
        isA<QuickAskException>().having(
          (e) => e.reason,
          'reason',
          QuickAskFailure.timeout,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    emit('first');
    await assertion;
    await transportCancel;
    emit('late');
    result.complete('late');
    expect(chunks, ['first']);
  });
}
