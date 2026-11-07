import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:flutter/services.dart';

import '../ide/lsp/lsp_protocol.dart';

/// The smallest server-reported callable containing the entire selection.
/// Callers must supply symbols validated against this exact snapshot version.
/// Invalid coordinates are rejected rather than clamped into unrelated code.
TextRange? quickAskEnclosingFunction(
  DocumentSnapshot snapshot,
  TextSelection selection,
  List<LspDocumentSymbol> symbols,
) {
  if (!selection.isValid ||
      selection.end > snapshot.text.length ||
      symbols.length > 10000) {
    return null;
  }
  int? offset(LspPosition position) {
    final line = position.line;
    final column = position.character;
    if (line < 0 || line >= snapshot.lineStarts.length || column < 0) {
      return null;
    }
    final start = snapshot.lineStarts[line];
    if (column > snapshot.contentEnds[line] - start) return null;
    final result = start + column;
    // LSP uses UTF-16, but a source range must not split a surrogate pair.
    if (result > 0 && result < snapshot.text.length) {
      final previous = snapshot.text.codeUnitAt(result - 1);
      final next = snapshot.text.codeUnitAt(result);
      if (previous >= 0xd800 &&
          previous <= 0xdbff &&
          next >= 0xdc00 &&
          next <= 0xdfff) {
        return null;
      }
    }
    return result;
  }

  TextRange? best;
  final pending = [...symbols];
  // A faulty server should not make a synchronous selection capture unbounded.
  var remaining = 10000;
  while (pending.isNotEmpty && remaining-- > 0) {
    final symbol = pending.removeLast();
    if (pending.length + symbol.children.length > 10000) return null;
    pending.addAll(symbol.children);
    if (symbol.kind != LspSymbolKind.function &&
        symbol.kind != LspSymbolKind.method &&
        symbol.kind != LspSymbolKind.constructor &&
        symbol.kind != LspSymbolKind.operator) {
      continue;
    }
    final start = offset(symbol.range.start);
    final end = offset(symbol.range.end);
    if (start == null ||
        end == null ||
        start >= end ||
        start > selection.start ||
        end < selection.end ||
        (selection.isCollapsed && selection.start == end)) {
      continue;
    }
    if (best == null || end - start < best.end - best.start) {
      best = TextRange(start: start, end: end);
    }
  }
  return pending.isEmpty ? best : null;
}
