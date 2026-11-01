import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ide/ide_button.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'learning_models.dart';

/// Explanation belongs to this operation, not a separate feed. Both parts
/// participate in normal transcript layout and scrolling; neither is overlaid.
class LearningOperationExplanation extends StatefulWidget {
  const LearningOperationExplanation({
    super.key,
    required this.child,
    this.card,
    this.enabled = true,
    this.onOpenEvidence,
  });

  final Widget child;
  final LearningCard? card;
  final bool enabled;
  final ValueChanged<LearningEvidence>? onOpenEvidence;

  @override
  State<LearningOperationExplanation> createState() =>
      _LearningOperationExplanationState();
}

class _LearningOperationExplanationState
    extends State<LearningOperationExplanation> {
  // Resizing or receiving a lesson must not reset an open diff's own state.
  final _operationKey = GlobalKey();
  final _bubbleKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final operation = KeyedSubtree(key: _operationKey, child: widget.child);
    final card = widget.card;
    if (!widget.enabled || card == null) return operation;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
        final bubbleWidth =
            (constraints.maxWidth >= 900 ? 248.0 : 228.0) * scale;
        final beside =
            constraints.hasBoundedWidth &&
            constraints.maxWidth >= math.max(760, 520 + 12 + bubbleWidth);
        final bubble = LearningBubble(
          key: _bubbleKey,
          card: card,
          pointsUp: !beside,
          onOpenEvidence: widget.onOpenEvidence,
        );
        if (beside) {
          return Row(
            key: const Key('learning-operation-row'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: operation),
              const SizedBox(width: 12),
              SizedBox(width: bubbleWidth, child: bubble),
            ],
          );
        }
        return Column(
          key: const Key('learning-operation-stacked'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            operation,
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(280, bubbleWidth),
                ),
                child: bubble,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Small, plain-text annotation. Model output never becomes a command, link,
/// rich-text markup or a source path. Only host-provided evidence is navigable.
class LearningBubble extends StatefulWidget {
  const LearningBubble({
    super.key,
    required this.card,
    this.pointsUp = false,
    this.onOpenEvidence,
  });

  final LearningCard card;
  final bool pointsUp;
  final ValueChanged<LearningEvidence>? onOpenEvidence;

  @override
  State<LearningBubble> createState() => _LearningBubbleState();
}

class _LearningBubbleState extends State<LearningBubble> {
  bool _expanded = false;

  String _t(String zh, String en) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;

  @override
  void didUpdateWidget(LearningBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.id != widget.card.id) _expanded = false;
  }

  TextStyle _style({bool muted = false, double size = 12}) => TextStyle(
    color: muted ? AppColors.textMuted : AppColors.text,
    fontSize: size,
    height: 1.45,
  );

  String get _shortWhy {
    final why = widget.card.why.trim();
    if (why.isEmpty) {
      return _t(
        '现有上下文不足，暂不判断原因。',
        'There is not enough context to infer a reason.',
      );
    }
    // The backend asks for two sentences; bound unexpected verbose replies in
    // the glance view as well. Expansion always offers the complete rationale.
    final sentences = RegExp(r'[^。！？.!?]+[。！？.!?]?')
        .allMatches(why)
        .take(2)
        .map((match) => match.group(0)!)
        .join()
        .trim();
    final concise = sentences.isEmpty ? why : sentences;
    return concise.length > 240 ? '${concise.substring(0, 240)}…' : concise;
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final fill = Color.alphaBlend(
      AppColors.accent.withValues(alpha: 0.045),
      AppColors.surface,
    );
    final border = AppColors.partBorder;
    final body = Container(
      key: Key('learning-bubble-${card.id}'),
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Codicons.lightbulb, size: 12, color: AppColors.accent),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _t('可能的原因', 'Possible rationale'),
                  style: _style(muted: true, size: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            _expanded && card.why.trim().isNotEmpty ? card.why : _shortWhy,
            style: _style(),
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
          ),
          if (_expanded) ...[
            _section(_t('知识点', 'Takeaway'), card.concept),
            if (card.tradeoff case final text?)
              _section(_t('权衡', 'Tradeoff'), text),
            if (card.example case final text?)
              _section(_t('例子', 'Example'), text),
            for (final evidence in card.evidence) ...[
              _section(_t('观察依据', 'Observed evidence'), evidence.label),
              if (evidence.excerpt.isNotEmpty)
                Text(
                  evidence.excerpt.length > 400
                      ? '${evidence.excerpt.substring(0, 400)}…'
                      : evidence.excerpt,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: _style(muted: true, size: 11),
                ),
              if (evidence.path != null && widget.onOpenEvidence != null) ...[
                const SizedBox(height: 6),
                _BubbleButton(
                  label: _t('只读查看当前文件', 'View current file · Read-only'),
                  onPressed: () => widget.onOpenEvidence!(evidence),
                ),
              ],
            ],
            const SizedBox(height: 8),
            Text(
              _t(
                '解释可见操作，不是 Agent 的内部思考。',
                'Based on visible work, not the agent’s private reasoning.',
              ),
              style: _style(muted: true, size: 10),
            ),
          ],
          const SizedBox(height: 7),
          _BubbleButton(
            key: Key('learning-bubble-expand-${card.id}'),
            label: _expanded ? _t('收起', 'Less') : _t('多学一点', 'A little more'),
            icon: _expanded ? Codicons.chevronUp : Codicons.chevronDown,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
        ],
      ),
    );
    final pointer = CustomPaint(
      key: Key(
        widget.pointsUp ? 'learning-pointer-up' : 'learning-pointer-left',
      ),
      size: widget.pointsUp ? const Size(14, 8) : const Size(12, 14),
      painter: _BubblePointer(fill: fill, border: border, up: widget.pointsUp),
    );
    if (widget.pointsUp) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: const Alignment(0.65, 0), child: pointer),
          body,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 16), child: pointer),
        Expanded(child: body),
      ],
    );
  }

  Widget _section(String title, String text) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: _style(muted: true, size: 10)),
        const SizedBox(height: 3),
        Text(text, style: _style(size: 11)),
      ],
    ),
  );
}

class _BubblePointer extends CustomPainter {
  const _BubblePointer({
    required this.fill,
    required this.border,
    required this.up,
  });
  final Color fill, border;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path.moveTo(0, size.height);
      path.lineTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(0, size.height / 2);
      path.lineTo(size.width, size.height);
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_BubblePointer oldDelegate) =>
      fill != oldDelegate.fill ||
      border != oldDelegate.border ||
      up != oldDelegate.up;
}

/// Keyboard support around the native control, including a visible focus ring.
class _BubbleButton extends StatefulWidget {
  const _BubbleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  @override
  State<_BubbleButton> createState() => _BubbleButtonState();
}

class _BubbleButtonState extends State<_BubbleButton> {
  bool _focus = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (value) => setState(() => _focus = value),
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onPressed();
          return null;
        },
      ),
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: _focus ? AppColors.accent : const Color(0x00000000),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: IdeButton(
          label: widget.label,
          onPressed: widget.onPressed,
          icon: widget.icon,
          secondary: true,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        ),
      ),
    ),
  );
}
