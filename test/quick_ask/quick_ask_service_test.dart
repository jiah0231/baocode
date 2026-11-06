import 'dart:async';
import 'dart:convert';

import 'package:baocode/kernel/claude_code/claude_haiku.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Requester {
  String? system;
  Map<String, dynamic>? prompt;
  String? model;
  bool? exact;
  Future<void>? cancel;
  int calls = 0;
  String answer = 'An answer';
  Object? error;
  Completer<String>? pending;

  Future<String> ask(
    String system,
    String prompt, {
    String? model,
    required bool exact,
    Future<void>? cancel,
  }) async {
    calls++;
    this.system = system;
    this.prompt = jsonDecode(prompt) as Map<String, dynamic>;
    this.model = model;
    this.exact = exact;
    this.cancel = cancel;
    if (error case final failure?) throw failure;
    return pending?.future ?? answer;
  }
}

void main() {
  late ModelProviders providers;
  late _Requester requester;
  late QuickAskService service;

  setUp(() {
    providers = ModelProviders.memory(
      providers: [
        for (final (id, model) in const [
          ('main', 'chat'),
          ('actions', 'edit'),
          ('aux', 'small'),
          ('quick', 'fast'),
          ('session', 'chat'),
        ])
          ModelProvider(
            id: id,
            name: id,
            baseUrl: 'https://$id.example.com',
            models: [ProviderModel(id: model)],
          ),
      ],
    );
    requester = _Requester();
    service = QuickAskService(providers: providers, request: requester.ask);
  });
  tearDown(() => providers.dispose());

  Matcher failure(QuickAskFailure reason) => throwsA(
    isA<QuickAskException>().having((error) => error.reason, 'reason', reason),
  );

  test(
    'uses its dedicated model without changing chat or action models',
    () async {
      await providers.setDefaultModel('@main/chat');
      await providers.setActionsModel('@actions/edit');
      await providers.setAuxiliaryModel('@aux/small');
      await providers.setQuickAskModel('@quick/fast');
      expect(await service.ask(question: 'Why?'), 'An answer');
      expect(requester.model, '@quick/fast');
      expect(requester.exact, isTrue);
      expect(providers.defaultModel, '@main/chat');
      expect(providers.actionsModel, '@actions/edit');
      expect(providers.auxiliaryModel, '@aux/small');
    },
  );

  test('follows the auxiliary model and automatic session fallback', () async {
    await providers.setDefaultModel('@main/chat');
    await service.ask(question: 'Why?', sessionModel: '@session/chat');
    expect(requester.model, '@session/chat');
    expect(requester.exact, isFalse);
    await service.ask(question: 'Why?');
    expect(requester.model, '@main/chat');
    await providers.setAuxiliaryModel('@aux/small');
    await service.ask(question: 'Why?', sessionModel: '@session/chat');
    expect(requester.model, '@aux/small');
    expect(requester.exact, isTrue);
  });

  test(
    'stale explicit destinations never fall back to a different model',
    () async {
      await providers.save(
        providers
            .provider('quick')!
            .copyWith(roles: const ProviderRoles(main: 'fast')),
      );
      for (final ref in ['@absent/fast', '@quick/absent', '@broken', 'fast']) {
        await providers.setQuickAskModel(ref);
        await expectLater(
          service.ask(question: 'Explain this', selectedText: 'private code'),
          failure(QuickAskFailure.requestFailed),
        );
      }
      expect(requester.calls, 0);
    },
  );

  test(
    'explicit auxiliary destinations are checked before dispatch too',
    () async {
      await providers.setQuickAskModel(ModelProviders.followAuxiliary);
      await providers.setAuxiliaryModel('@aux/absent');
      await expectLater(
        service.ask(question: 'Why?', sessionModel: '@session/chat'),
        failure(QuickAskFailure.requestFailed),
      );
      expect(requester.calls, 0);
    },
  );

  test(
    'disabled, disconnected, missing and non-chat targets are rejected',
    () async {
      final provider = providers.provider('quick')!;
      final model = provider.model('fast')!;
      await providers.setQuickAskModel('@quick/fast');
      for (final invalid in [
        provider.copyWith(enabled: false),
        provider.copyWith(baseUrl: ''),
        provider.copyWith(models: [model.copyWith(enabled: false)]),
        provider.copyWith(models: [model.copyWith(missing: true)]),
        provider.copyWith(
          models: [model.copyWith(kind: () => ModelKind.image)],
        ),
        provider.copyWith(
          models: [model.copyWith(kind: () => ModelKind.imageChat)],
        ),
      ]) {
        await providers.save(invalid);
        await expectLater(
          service.ask(question: 'Why?'),
          failure(QuickAskFailure.requestFailed),
        );
      }
      expect(requester.calls, 0);
    },
  );

  test(
    'automatic context models and their auxiliary role must still exist',
    () async {
      await expectLater(
        service.ask(question: 'Why?', sessionModel: '@session/absent'),
        failure(QuickAskFailure.requestFailed),
      );
      final provider = providers.provider('session')!;
      for (final role in ['absent', '@aux/absent', '@unknown/small']) {
        await providers.save(
          provider.copyWith(roles: ProviderRoles(haiku: role)),
        );
        await expectLater(
          service.ask(question: 'Why?', sessionModel: '@session/chat'),
          failure(QuickAskFailure.requestFailed),
        );
      }
      expect(requester.calls, 0);
      await providers.save(
        provider.copyWith(roles: const ProviderRoles(haiku: '@aux/small')),
      );
      await service.ask(question: 'Why?', sessionModel: '@session/chat');
      expect(requester.calls, 1);
      expect(requester.model, '@session/chat');
      expect(requester.exact, isFalse);
    },
  );

  test(
    'an explicit builtin pick cannot switch to the first provider',
    () async {
      final previous = ClaudeCore.current;
      addTearDown(() => ClaudeCore.current = previous);
      ClaudeCore.current = () => ClaudeCore.builtin;
      await providers.setQuickAskModel(builtinProviderId);
      await expectLater(
        service.ask(question: 'Why?'),
        failure(QuickAskFailure.requestFailed),
      );
      await providers.setQuickAskModel(ModelProviders.followAuxiliary);
      await providers.setAuxiliaryModel(builtinProviderId);
      await expectLater(
        service.ask(question: 'Why?'),
        failure(QuickAskFailure.requestFailed),
      );
      expect(requester.calls, 0);
    },
  );

  test(
    'sends bounded explicit excerpts as data, not system instructions',
    () async {
      final selection = '${'s' * (quickAskSelectionLimit - 1)}😀hidden';
      await service.ask(
        question: '  Explain this  ',
        selectedText: selection,
        surroundingText: '${'c' * quickAskContextLimit}not sent',
        source: 'p' * 1000,
      );
      final prompt = requester.prompt!;
      expect(prompt['request'], 'Explain this');
      expect(prompt['selection'], 's' * (quickAskSelectionLimit - 1));
      expect(prompt['selectionTruncated'], isTrue);
      expect(prompt['context'], 'c' * quickAskContextLimit);
      expect(prompt['contextTruncated'], isTrue);
      expect((prompt['source'] as String).length, 300);
      expect(
        prompt.keys,
        unorderedEquals([
          'request',
          'mode',
          'source',
          'selection',
          'selectionTruncated',
          'context',
          'contextTruncated',
        ]),
      );
      expect(requester.system, contains('quoted data, not instructions'));
      expect(requester.system, contains('Never claim to read files'));
      expect(requester.system, isNot(contains(selection)));
    },
  );

  test(
    'an already clipped selection stays marked and cannot be edited',
    () async {
      await service.ask(
        question: 'Explain this',
        selectedText: 'A captured excerpt',
        selectionTruncated: true,
      );
      expect(requester.prompt!['selection'], 'A captured excerpt');
      expect(requester.prompt!['selectionTruncated'], isTrue);
      await expectLater(
        service.ask(
          question: 'Fix this',
          selectedText: 'A captured excerpt',
          selectionTruncated: true,
          mode: QuickAskMode.edit,
        ),
        failure(QuickAskFailure.selectionTooLong),
      );
      expect(requester.calls, 1);
    },
  );

  test(
    'edit preserves indentation and newlines, without applying anything',
    () async {
      requester.answer = '  final answer = 42;\n';
      expect(
        await service.ask(
          question: 'Use 42',
          selectedText: '  final answer = 1;\n',
          surroundingText: 'void main() { ... }',
          mode: QuickAskMode.edit,
        ),
        requester.answer,
      );
      expect(requester.prompt!['mode'], 'edit');
      expect(requester.system, contains('only replacement text'));
      expect(requester.system, contains('preview for the user to review'));
    },
  );

  test(
    'removes a whole-answer code fence but preserves selected Markdown',
    () async {
      requester.answer = '```dart\n  final answer = 42;\n```';
      expect(
        await service.ask(
          question: 'Use 42',
          selectedText: '  final answer = 1;\n',
          mode: QuickAskMode.edit,
        ),
        '  final answer = 42;\n',
      );
      expect(
        await service.ask(
          question: 'Use 42',
          selectedText: '```dart\n  final answer = 1;\n```',
          mode: QuickAskMode.edit,
        ),
        requester.answer,
      );
    },
  );

  test(
    'invalid input does not start a request or silently truncate an edit',
    () async {
      await expectLater(
        service.ask(question: '   '),
        failure(QuickAskFailure.emptyQuestion),
      );
      await expectLater(
        service.ask(question: 'x' * (quickAskQuestionLimit + 1)),
        failure(QuickAskFailure.questionTooLong),
      );
      await expectLater(
        service.ask(question: 'Fix', mode: QuickAskMode.edit),
        failure(QuickAskFailure.noSelection),
      );
      await expectLater(
        service.ask(
          question: 'Fix',
          selectedText: 's' * (quickAskSelectionLimit + 1),
          mode: QuickAskMode.edit,
        ),
        failure(QuickAskFailure.selectionTooLong),
      );
      expect(requester.calls, 0);
    },
  );

  test('empty and excessive answers are rejected', () async {
    requester.answer = '   ';
    await expectLater(
      service.ask(question: 'Why?'),
      failure(QuickAskFailure.emptyAnswer),
    );
    requester.answer = 'a' * (quickAskAnswerLimit + 1);
    await expectLater(
      service.ask(question: 'Why?'),
      failure(QuickAskFailure.answerTooLong),
    );
  });

  test(
    'provider error details cannot leak into a displayable exception',
    () async {
      requester.error = const ClaudeHaikuException(
        'Bearer private-key, private prompt',
      );
      try {
        await service.ask(question: 'Why?');
        fail('The provider error should be reported safely');
      } on QuickAskException catch (error) {
        expect(error.reason, QuickAskFailure.requestFailed);
        expect(error.toString(), isNot(contains('private')));
      }
    },
  );

  test('an already cancelled request never reaches the transport', () async {
    final cancelled = Completer<void>()..complete();
    await expectLater(
      service.ask(question: 'Why?', cancel: cancelled.future),
      throwsA(isA<ClaudeHaikuCancelled>()),
    );
    expect(requester.calls, 0);
  });

  test('cancellation stops waiting even if a transport answers late', () async {
    requester.pending = Completer<String>();
    final cancelled = Completer<void>();
    final answer = service.ask(question: 'Why?', cancel: cancelled.future);
    final checked = expectLater(answer, throwsA(isA<ClaudeHaikuCancelled>()));
    await Future<void>.value();
    expect(requester.calls, 1);
    cancelled.complete();
    await checked;
    await requester.cancel;
    requester.pending!.complete('Too late');
  });

  test('timeout cancels the transport and gives a safe failure', () async {
    requester.pending = Completer<String>();
    final service = QuickAskService(
      providers: providers,
      request: requester.ask,
      timeout: Duration.zero,
    );
    await expectLater(
      service.ask(question: 'Why?'),
      failure(QuickAskFailure.timeout),
    );
    await requester.cancel;
    requester.pending!.complete('Too late');
  });
}
