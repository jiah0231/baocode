import 'dart:async';

import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/ide/lsp_ui/document_symbols.dart';
import 'package:baocode/quick_ask/quick_ask_symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ide/lsp_ui/fake_language_features.dart';

LspDocumentSymbol symbol(
  int start,
  int end, {
  LspSymbolKind kind = LspSymbolKind.function,
  List<LspDocumentSymbol> children = const [],
}) => LspDocumentSymbol(
  name: 'function',
  kind: kind,
  range: LspRange(LspPosition(0, start), LspPosition(0, end)),
  selectionRange: LspRange(LspPosition(0, start), LspPosition(0, start + 1)),
  children: children,
);

class _PendingLanguages extends FakeLanguageFeatures {
  final answers = <Completer<List<LspDocumentSymbol>>>[];
  @override
  Future<List<LspDocumentSymbol>> documentSymbols(String path) {
    final answer = Completer<List<LspDocumentSymbol>>();
    answers.add(answer);
    return answer.future;
  }
}

void main() {
  test('selects smallest callable, not containing class or sibling', () {
    final snapshot = DocumentSnapshot(' ' * 100);
    final symbols = [
      symbol(
        0,
        100,
        kind: LspSymbolKind.klass,
        children: [
          symbol(2, 60, kind: LspSymbolKind.method, children: [symbol(10, 30)]),
          symbol(70, 90, kind: LspSymbolKind.constructor),
        ],
      ),
    ];
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection(baseOffset: 25, extentOffset: 15),
        symbols,
      ),
      const TextRange(start: 10, end: 30),
    );
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection(baseOffset: 20, extentOffset: 80),
        symbols,
      ),
      isNull,
    );
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection.collapsed(offset: 90),
        symbols,
      ),
      isNull,
    );
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection(baseOffset: 70, extentOffset: 90),
        symbols,
      ),
      const TextRange(start: 70, end: 90),
    );
  });

  test(
    'rejects invalid positions, reversed ranges and surrogate boundaries',
    () {
      final snapshot = DocumentSnapshot('😀abcdef');
      for (final invalid in [
        symbol(-1, 8),
        symbol(0, 9),
        symbol(5, 3),
        symbol(1, 8),
        symbol(0, 1),
      ]) {
        expect(
          quickAskEnclosingFunction(
            snapshot,
            const TextSelection.collapsed(offset: 4),
            [invalid],
          ),
          isNull,
        );
      }
      expect(
        quickAskEnclosingFunction(
          snapshot,
          const TextSelection.collapsed(offset: -1),
          [symbol(0, 8)],
        ),
        isNull,
      );
    },
  );

  test('rejects excessive server symbol trees without unbounded traversal', () {
    final snapshot = DocumentSnapshot('example');
    final symbols = List.filled(10001, symbol(0, 7));
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection.collapsed(offset: 2),
        symbols,
      ),
      isNull,
    );
    var nested = symbol(0, 7);
    for (var i = 0; i < 10001; i++) {
      nested = symbol(0, 7, children: [nested]);
    }
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection.collapsed(offset: 2),
        [nested],
      ),
      isNull,
    );
  });

  test('maps UTF-16 columns and CRLF without offset clamping', () {
    final snapshot = DocumentSnapshot('head\r\n😀call();\r\nend');
    final function = LspDocumentSymbol(
      name: 'call',
      kind: LspSymbolKind.function,
      range: const LspRange(LspPosition(1, 0), LspPosition(1, 9)),
      selectionRange: const LspRange(LspPosition(1, 2), LspPosition(1, 6)),
    );
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection(baseOffset: 8, extentOffset: 12),
        [function],
      ),
      const TextRange(start: 6, end: 15),
    );
    final invalid = LspDocumentSymbol(
      name: 'bad',
      kind: LspSymbolKind.function,
      range: const LspRange(LspPosition(0, 0), LspPosition(10, 0)),
      selectionRange: function.selectionRange,
    );
    expect(
      quickAskEnclosingFunction(
        snapshot,
        const TextSelection.collapsed(offset: 8),
        [invalid],
      ),
      isNull,
    );
  });

  test(
    'cache rejects stale responses, undo and same-path replacement',
    () async {
      final languages = _PendingLanguages();
      final cache = IdeDocumentSymbols(languages);
      final document = IdeDocument('/a.dart', 'void f() {}');
      final replacement = IdeDocument('/a.dart', document.text);
      addTearDown(cache.dispose);
      addTearDown(document.model.dispose);
      addTearDown(replacement.model.dispose);
      cache.update(document);
      final symbols = [symbol(0, document.text.length)];
      languages.answers.last.complete(symbols);
      await Future<void>.delayed(Duration.zero);
      expect(cache.currentSymbols(document), symbols);
      expect(cache.currentSymbols(replacement), isEmpty);
      document.model.applyOffsetEdits([const EditorOffsetEdit(0, 0, '!')]);
      expect(cache.currentSymbols(document), isEmpty);
      cache.refresh();
      document.model.undo();
      languages.answers.last.complete(symbols);
      await Future<void>.delayed(Duration.zero);
      expect(cache.currentSymbols(document), isEmpty);
      cache.refresh();
      final oldRequest = languages.answers.last;
      cache.update(replacement);
      oldRequest.complete(symbols);
      await Future<void>.delayed(Duration.zero);
      expect(cache.currentSymbols(replacement), isEmpty);
      languages.answers.last.complete(symbols);
      await Future<void>.delayed(Duration.zero);
      expect(cache.currentSymbols(replacement), symbols);
    },
  );
}
