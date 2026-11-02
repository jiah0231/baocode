import 'dart:async';
import 'dart:typed_data';

import 'package:bao_editor/monaco/vs/workbench/services/text_mate/browser/background_tokenization/worker/text_mate_worker_tokenizer.dart';
import 'package:bao_editor/monaco/vs/workbench/services/text_mate/common/tm_grammar_factory.dart';
import 'package:bao_editor/textmate/vscode_textmate/main.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

// Force the normal time-budget yield without sleeping or depending on CPU speed.
class _ExpiredStopwatch implements Stopwatch {
  @override
  int get elapsedMilliseconds => 21;

  @override
  void start() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Grammar implements IGrammar {
  @override
  ITokenizeLineResult2 tokenizeLine2(
    String lineText,
    StateStack? prevState, [
    int timeLimit = 0,
  ]) => ITokenizeLineResult2(
    tokens: Uint32List.fromList([0, 0]),
    fonts: const [],
    ruleStack: prevState ?? INITIAL,
    stoppedEarly: false,
  );

  @override
  ITokenizeLineResult tokenizeLine(
    String lineText,
    StateStack? prevState, [
    int timeLimit = 0,
  ]) => throw UnimplementedError('Only encoded tokens are requested.');
}

class _Host implements TextMateModelTokenizerHost {
  final grammar = Completer<ICreateGrammarResult?>();
  int publications = 0;
  void Function()? onTokens;

  void load() => grammar.complete(
    ICreateGrammarResult(
      languageId: 'test',
      grammar: _Grammar(),
      initialState: INITIAL,
      containsEmbeddedLanguages: false,
    ),
  );

  @override
  Future<ICreateGrammarResult?> getOrCreateGrammar(
    String languageId,
    int encodedLanguageId,
  ) => grammar.future;

  @override
  void setTokens(
    int versionId,
    List<(int lineNumber, Uint32List tokens)> tokens, {
    bool heuristic = false,
  }) {
    publications++;
    onTokens?.call();
  }
}

TextMateWorkerTokenizer _tokenizer(_Host host) => TextMateWorkerTokenizer(
  ['first', 'second'],
  1,
  host,
  'test',
  1,
  1000,
  createStopwatch: _ExpiredStopwatch.new,
);

void main() {
  test('dispose cancels a queued yield, including repeated disposal', () {
    fakeAsync((async) {
      final host = _Host();
      final tokenizer = _tokenizer(host);
      host.load();
      async.flushMicrotasks();
      expect(host.publications, 1);
      expect(async.nonPeriodicTimerCount, 1);
      tokenizer.dispose();
      tokenizer.dispose();
      expect(async.nonPeriodicTimerCount, 0);
      tokenizer.acceptChange(2, 1, 2, ['changed']);
      tokenizer.retokenize(1, 3);
      tokenizer.onLanguageId('next', 2);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(async.nonPeriodicTimerCount, 0);
      expect(host.publications, 1);
    });
  });

  test('grammar completion after dispose cannot restart tokenization', () {
    fakeAsync((async) {
      final host = _Host();
      final tokenizer = _tokenizer(host);
      tokenizer.dispose();
      host.load();
      async.flushMicrotasks();
      expect(host.publications, 0);
      expect(async.nonPeriodicTimerCount, 0);
    });
  });

  test('disposing one document does not cancel another document yield', () {
    fakeAsync((async) {
      final first = _Host();
      final second = _Host();
      final a = _tokenizer(first);
      final b = _tokenizer(second);
      first.load();
      second.load();
      async.flushMicrotasks();
      expect(async.nonPeriodicTimerCount, 2);
      a.dispose();
      expect(async.nonPeriodicTimerCount, 1);
      async.elapse(Duration.zero);
      expect(first.publications, 1);
      expect(second.publications, 2);
      expect(async.nonPeriodicTimerCount, 0);
      b.dispose();
    });
  });

  test('host disposal while accepting tokens does not enqueue a new yield', () {
    fakeAsync((async) {
      final host = _Host();
      final tokenizer = _tokenizer(host);
      host.onTokens = tokenizer.dispose;
      host.load();
      async.flushMicrotasks();
      expect(host.publications, 1);
      expect(async.nonPeriodicTimerCount, 0);
    });
  });

  test('dispose also cancels a pending change debounce', () {
    fakeAsync((async) {
      final host = _Host();
      final tokenizer = _tokenizer(host);
      tokenizer.acceptChange(2, 1, 2, ['changed']);
      expect(async.nonPeriodicTimerCount, 1);
      tokenizer.dispose();
      host.load();
      async.flushMicrotasks();
      expect(async.nonPeriodicTimerCount, 0);
      expect(host.publications, 0);
    });
  });
}
