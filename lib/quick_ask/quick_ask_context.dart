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
    this.sessionModel,
    this.truncated = false,
    this.applyReplacement,
    this.selectionAnchor,
    this.selectionAnchorListenable,
  });

  static const maxSelectionLength = 8000;
  static const maxContextLength = 4000;

  final String selectedText;
  final String contextText;
  final String sourceLabel;

  /// The originating chat's model route, captured before focus changes. This
  /// is routing metadata only, never an extra conversation excerpt.
  final String? sessionModel;

  /// The selection, not merely its surroundings, was clipped. Never apply a
  /// proposed replacement to a larger range than the model actually saw.
  final bool truncated;

  /// An explicit, previewed edit only. False means the source is no longer
  /// current. Sent chat messages never provide this callback.
  final FutureOr<bool> Function(String replacement)? applyReplacement;

  /// Resolves the captured selection's active end in global logical pixels.
  /// Independent of focus/current selection; null if its source is no longer
  /// laid out or visible. Call again after source scrolling or layout changes.
  final Rect? Function()? selectionAnchor;

  /// Source geometry changes. Consumers resolve after layout, not in this
  /// notification, since scroll notifications can precede the next layout.
  final Listenable? selectionAnchorListenable;

  bool get canApply =>
      !truncated && selectedText.isNotEmpty && applyReplacement != null;

  /// Captures a selection, or the cursor's neighborhood when it is collapsed.
  /// [applyReplacement] must independently revalidate its source on use.
  factory QuickAskContext.fromText({
    required String text,
    required TextSelection selection,
    required String sourceLabel,
    String? sessionModel,
    FutureOr<bool> Function(String replacement)? applyReplacement,
    Rect? Function()? selectionAnchor,
    Listenable? selectionAnchorListenable,
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
      selectionAnchor: selectionAnchor,
      selectionAnchorListenable: selectionAnchorListenable,
      selectedText: selected,
      contextText:
          '${suffix(text.substring(math.max(0, start - before - 1), start), before)}$marker${prefix(text.substring(end, math.min(text.length, end + after + 1)), after)}',
      sourceLabel: sourceLabel,
      sessionModel: sessionModel,
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
    String? sessionModel,
    required bool Function() isCurrent,
    bool readOnly = false,
    Rect? Function()? selectionAnchor,
    Listenable? selectionAnchorListenable,
  }) {
    final document = controller.document;
    final version = document.version;
    final text = document.text;
    final selection = controller.value.selection;
    var used = false;
    return QuickAskContext.fromText(
      text: text,
      selection: selection,
      selectionAnchor: selectionAnchor,
      selectionAnchorListenable: selectionAnchorListenable,
      sourceLabel: sourceLabel,
      sessionModel: sessionModel,
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

  /// The innermost focused surface owns the excerpt and edit target. A nested
  /// code editor may inherit a chat's model route, without capturing its text.
  static QuickAskContext? captureOf(BuildContext? context) {
    if (context == null || !context.mounted) return null;
    QuickAskContext? captured;
    String? sessionModel;
    bool visit(Element element) {
      if (element case StatefulElement(:final QuickAskTarget state)) {
        captured ??= state.captureQuickAskContext();
        sessionModel ??= captured?.sessionModel ?? state.quickAskSessionModel;
      }
      return captured == null || sessionModel == null;
    }

    if (context is! Element || visit(context)) {
      context.visitAncestorElements(visit);
    }
    final result = captured;
    if (result == null || result.sessionModel != null || sessionModel == null) {
      return result;
    }
    return QuickAskContext(
      selectedText: result.selectedText,
      contextText: result.contextText,
      sourceLabel: result.sourceLabel,
      sessionModel: sessionModel,
      truncated: result.truncated,
      applyReplacement: result.applyReplacement,
      selectionAnchor: result.selectionAnchor,
      selectionAnchorListenable: result.selectionAnchorListenable,
    );
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
  /// Routing for focused descendants, independent of this target's excerpt.
  String? get quickAskSessionModel => null;

  QuickAskContext? captureQuickAskContext();
}
