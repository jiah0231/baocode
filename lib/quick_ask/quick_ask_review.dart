import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'quick_ask_diff.dart';
import 'quick_ask_popup.dart';

/// Result-only controls; the idle popup still has just its Chat/Agent switch.
class QuickAskReview extends StatelessWidget {
  const QuickAskReview({
    super.key,
    required this.diff,
    required this.enabled,
    required this.onChanged,
  });

  final QuickAskDiff diff;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = themeColors;
    Widget lines(String text, String other, bool? added) {
      var shown = text.replaceAll('\r\n', '\n');
      if (shown.endsWith('\n')) shown = shown.substring(0, shown.length - 1);
      final sign = added == null
          ? ' '
          : added
          ? '+'
          : '−';
      var ending = '';
      if (added != null && text.endsWith('\n') != other.endsWith('\n')) {
        ending = text.endsWith('\n') ? '↵' : 'EOF';
      } else if (added != null &&
          text.contains('\r\n') != other.contains('\r\n')) {
        ending = text.contains('\r\n') ? 'CRLF' : 'LF';
      }
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        color: added == null
            ? null
            : colors[added
                  ? 'diffEditor.insertedTextBackground'
                  : 'diffEditor.removedTextBackground'],
        child: SelectableText(
          '$sign ${shown.replaceAll('\n', '\n$sign ')}${ending.isEmpty ? '' : '\n\\ $ending'}',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
            color: colors['editorWidget.foreground'],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          diff.hunks.isEmpty ? l10n.sidePanelUnchanged : l10n.quickAskApplyHint,
        ),
        for (var i = 0; i < diff.hunks.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DecoratedBox(
              key: ValueKey('quick-ask-hunk-$i'),
              decoration: BoxDecoration(
                border: Border.all(
                  color: colors['editorWidget.foreground'].withValues(
                    alpha: 0.16,
                  ),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${l10n.quickAskSelection} · ${l10n.toolLines('${diff.hunks[i].line}')}',
                          ),
                        ),
                        QuickAskAction(
                          key: ValueKey('quick-ask-keep-$i'),
                          label: l10n.stripKeep,
                          icon: Codicons.check,
                          selected: diff.hunks[i].included,
                          onPressed: !enabled
                              ? null
                              : () {
                                  diff.hunks[i].included = true;
                                  onChanged();
                                },
                        ),
                        QuickAskAction(
                          key: ValueKey('quick-ask-reject-$i'),
                          label: l10n.stripUndo,
                          icon: Codicons.close,
                          selected: !diff.hunks[i].included,
                          onPressed: !enabled
                              ? null
                              : () {
                                  diff.hunks[i].included = false;
                                  onChanged();
                                },
                        ),
                      ],
                    ),
                  ),
                  if (diff.hunks[i].original.isNotEmpty)
                    lines(
                      diff.hunks[i].original,
                      diff.hunks[i].proposed,
                      diff.hunks[i].included ? false : null,
                    ),
                  if (diff.hunks[i].included &&
                      diff.hunks[i].proposed.isNotEmpty)
                    lines(diff.hunks[i].proposed, diff.hunks[i].original, true),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
