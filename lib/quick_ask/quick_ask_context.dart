import 'dart:async';
import 'dart:math' as math;

import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:flutter/widgets.dart';

/// A snapshot taken before the quick-ask window takes keyboard focus.
/// Only the selected text and its bounded neighborhood leave the editor.
class QuickAskContext {
  const QuickAskContext({
    this.selectedText = '',
    this.contextText = '',
    required this.sourceLabel,
    this.truncated = false,
    this.applyReplacement,
  });

  static const maxSelectionLength = 8000;
  static const maxContextLength = 4000;

  final String selectedText;
  final String contextText;
  final String sourceLabel;

  /// The selection, not merely its surroundings, was clipped. Never apply a
  /// proposed replacement to a larger range than the model actually saw.
  final bool truncated;

  /// An explicit, previewed edit only. False means the source is no longer
  /// current. Sent chat messages never provide this callback.
  final FutureOr<bool> Function(String replacement)? applyReplacement;

  bool get canApply =>
      !truncated && selectedText.isNotEmpty && applyReplacement != null;

  /// Captures a selection, or the cursor's neighborhood when it is collapsed.
  /// [applyReplacement] must independently revalidate its source on use.
  factory QuickAskContext.fromText({
    required String text,
    required TextSelection selection,
    required String sourceLabel,
    FutureOr<bool> Function(String replacement)? applyReplacement,
  }) {
    final valid = selection.isValid && selection.end <= text.length;
    final start = valid ? selection.start : text.length;
    final end = valid ? selection.end : text.length;
    final truncated = end - start > maxSelectionLength;
    final selected = prefix(
      text.substring(start, math.min(end, start + maxSelectionLength + 1)),
      maxSelectionLength,
    );
    final marker = start == end ? '' : '\n[selection]\n';
    final available = maxContextLength - marker.length;
    var before = math.min(start, available ~/ 2);
    final after = math.min(text.length - end, available - before);
    before = math.min(start, available - after);
    return QuickAskContext(
      selectedText: selected,
      contextText:
          '${suffix(text.substring(math.max(0, start - before - 1), start), before)}$marker${prefix(text.substring(end, math.min(text.length, end + after + 1)), after)}',
      sourceLabel: sourceLabel,
      truncated: truncated,
      applyReplacement: valid && start != end && !truncated
          ? applyReplacement
          : null,
    );
  }

  /// A single, undoable native editor replacement. Changes to the buffer,
  /// including an edit followed by Undo, invalidate the captured revision.
  factory QuickAskContext.fromEditor({
    required EditorSurfaceController controller,
    required String sourceLabel,
    required bool Function() isCurrent,
    bool readOnly = false,
  }) {
    final document = controller.document;
    final version = document.version;
    final text = document.text;
    final selection = controller.value.selection;
    var used = false;
    return QuickAskContext.fromText(
      text: text,
      selection: selection,
      sourceLabel: sourceLabel,
      applyReplacement: readOnly || controller.selections.length != 1
          ? null
          : (replacement) {
              // Check widget lifetime before touching its disposed controller.
              if (used || !isCurrent() || document.version != version) {
                return false;
              }
              used = true;
              if (selection.textInside(text) == replacement) return true;
              return controller.applyEdits([
                EditorOffsetEdit(selection.start, selection.end, replacement),
              ]);
            },
    );
  }

  static QuickAskContext? captureFocused() =>
      captureOf(FocusManager.instance.primaryFocus?.context);

  /// The innermost focused surface wins; a code block's own editor therefore
  /// wins over the conversation that contains it.
  static QuickAskContext? captureOf(BuildContext? context) {
    if (context == null || !context.mounted) return null;
    QuickAskContext? captured;
    bool visit(Element element) {
      if (element case StatefulElement(:final QuickAskTarget state)) {
        captured = state.captureQuickAskContext();
      }
      return captured == null;
    }

    if (context is Element && !visit(context)) return captured;
    context.visitAncestorElements(visit);
    return captured;
  }

  /// Clips without leaving half of a UTF-16 surrogate pair at the boundary.
  static String prefix(String text, int limit) {
    if (text.length <= limit) return text;
    var end = limit;
    if (end > 0 &&
        _highSurrogate(text.codeUnitAt(end - 1)) &&
        _lowSurrogate(text.codeUnitAt(end))) {
      end--;
    }
    return text.substring(0, end);
  }

  static String suffix(String text, int limit) {
    if (text.length <= limit) return text;
    var start = text.length - limit;
    if (start < text.length &&
        _lowSurrogate(text.codeUnitAt(start)) &&
        start > 0 &&
        _highSurrogate(text.codeUnitAt(start - 1))) {
      start++;
    }
    return text.substring(start);
  }

  static bool _highSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
  static bool _lowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
}

mixin QuickAskTarget<T extends StatefulWidget> on State<T> {
  QuickAskContext? captureQuickAskContext();
}
