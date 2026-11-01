import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../ide/ide_button.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'learning_models.dart';

/// Session-owned presentation only; no evidence or generated content is copied.
/// Keeping this outside the widget preserves reading position when the rail
/// temporarily shows a file. A different conversation uses a different instance.
class LearningReadingState {
  final Set<String> _expanded = {};
  bool _following = true;
  bool _recap = false;
  int _unread = 0;
  double _scrollOffset = 0;

  Set<String> get expandedIds => Set.unmodifiable(_expanded);
  bool get following => _following;
  bool get recapExpanded => _recap;
  int get unreadCount => _unread;
  double get scrollOffset => _scrollOffset;
}

/// A quiet, presentational rail. Generated strings are plain text, never
/// markdown/HTML, commands or navigable model-supplied URLs.
class LearningPanel extends StatefulWidget {
  const LearningPanel({
    super.key,
    required this.cards,
    required this.enabled,
    required this.onConfigure,
    required this.onTogglePause,
    required this.onDisable,
    this.paused = false,
    this.busy = false,
    this.budgetReached = false,
    this.error,
    this.modelLabel,
    this.onOpenEvidence,
    this.sessionKey = '',
    this.readingState,
  });

  final List<LearningCard> cards;
  final bool enabled, paused, busy, budgetReached;
  final String? error, modelLabel;
  final VoidCallback onConfigure, onTogglePause, onDisable;
  final ValueChanged<LearningEvidence>? onOpenEvidence;
  final String sessionKey;
  final LearningReadingState? readingState;

  @override
  State<LearningPanel> createState() => _LearningPanelState();
}

class _LearningPanelState extends State<LearningPanel> {
  late LearningReadingState _reading;
  late final ScrollController _scroll;
  bool _restoring = false;
  Set<String> get _expanded => _reading._expanded;
  bool get _following => _reading._following;
  set _following(bool value) => _reading._following = value;
  bool get _recap => _reading._recap;
  set _recap(bool value) => _reading._recap = value;
  int get _unread => _reading._unread;
  set _unread(int value) => _reading._unread = value;

  @override
  void initState() {
    super.initState();
    _reading = widget.readingState ?? LearningReadingState();
    _expanded.retainAll(widget.cards.map((card) => card.id));
    _scroll = ScrollController(
      initialScrollOffset: _reading._scrollOffset,
      keepScrollOffset: false,
    );
    _scroll.addListener(_saveScroll);
  }

  void _saveScroll() {
    if (!_restoring && _scroll.hasClients) {
      _reading._scrollOffset = _scroll.offset;
    }
  }

  void _restoreScroll() {
    final reading = _reading;
    final offset = reading._scrollOffset;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(reading, _reading) || !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
      _restoring = false;
      _saveScroll();
    });
  }

  String _t(String zh, String en) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;

  @override
  void didUpdateWidget(LearningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionKey != widget.sessionKey ||
        !identical(oldWidget.readingState, widget.readingState)) {
      _saveScroll();
      _reading = widget.readingState ?? LearningReadingState();
      _expanded.retainAll(widget.cards.map((card) => card.id));
      _restoreScroll();
      return;
    }
    final oldIds = oldWidget.cards.map((card) => card.id).toSet();
    final added = widget.cards
        .where((card) => !oldIds.contains(card.id))
        .length;
    if (added > 0) {
      if (_following) {
        _jumpToLatest();
      } else {
        _unread += added;
      }
    }
    _expanded.retainAll(widget.cards.map((card) => card.id));
  }

  void _jumpToLatest() {
    final reading = _reading;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(reading, _reading) &&
          _following &&
          _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _followLatest() {
    setState(() {
      _following = true;
      _unread = 0;
      _expanded.clear();
    });
    _jumpToLatest();
  }

  @override
  void dispose() {
    _saveScroll();
    _scroll.removeListener(_saveScroll);
    _scroll.dispose();
    super.dispose();
  }

  TextStyle _style({
    double size = 13,
    bool muted = false,
    bool strong = false,
  }) => TextStyle(
    fontSize: size,
    height: 1.45,
    color: muted ? AppColors.textMuted : AppColors.text,
    fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
  );

  @override
  Widget build(BuildContext context) {
    final status = !widget.enabled
        ? _t('未开启', 'Off')
        : widget.paused
        ? _t('已暂停', 'Paused')
        : _t('轻量讲解', 'Quiet learning');
    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Codicons.lightbulb, size: 16, color: AppColors.accent),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _t('边看边学', 'Learn as you go'),
                        style: _style(strong: true),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(status, style: _style(size: 11, muted: true)),
                  ],
                ),
                if (widget.modelLabel case final label?) ...[
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _style(size: 11, muted: true),
                  ),
                ],
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _LearningButton(
                      key: const Key('learning-configure'),
                      label: _t('讲解设置', 'Settings'),
                      icon: Codicons.settingsGear,
                      secondary: true,
                      onPressed: widget.onConfigure,
                    ),
                    if (widget.enabled) ...[
                      _LearningButton(
                        key: const Key('learning-pause'),
                        label: widget.paused
                            ? _t('继续', 'Resume')
                            : _t('暂停', 'Pause'),
                        icon: widget.paused
                            ? Codicons.play
                            : Codicons.debugPause,
                        secondary: true,
                        onPressed: widget.onTogglePause,
                      ),
                      _LearningButton(
                        key: const Key('learning-disable'),
                        label: _t('关闭', 'Turn off'),
                        secondary: true,
                        onPressed: widget.onDisable,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Container(height: 1, color: AppColors.partBorder),
          Expanded(
            child: NotificationListener<UserScrollNotification>(
              onNotification: (notification) {
                if (notification.direction != ScrollDirection.idle &&
                    _following) {
                  setState(() => _following = false);
                }
                return false;
              },
              child: ListView(
                key: const Key('learning-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  if (widget.cards.isEmpty) _empty(),
                  if (widget.cards.isNotEmpty && !widget.enabled)
                    _notice(
                      _t(
                        '讲解已关闭。已有卡片仍保留在此。',
                        'Learning is off. Your existing cards stay here.',
                      ),
                    ),
                  if (widget.paused && widget.enabled)
                    _notice(
                      _t(
                        '已暂停 · 不再发送新的上下文',
                        'Paused · No new context is being sent',
                      ),
                    ),
                  if (widget.error != null)
                    _notice(
                      _t(
                        '这次未能生成讲解。已有内容不受影响；请检查讲解设置。',
                        'Could not prepare this explanation. Existing cards are safe; check your learning settings.',
                      ),
                    ),
                  if (widget.budgetReached)
                    _notice(
                      _t(
                        '本次会话已达到讲解上限，先消化已有知识吧。',
                        'This session’s learning limit is reached. Take a moment to revisit your cards.',
                      ),
                    ),
                  if (widget.cards.length >= 3) _recapCard(),
                  for (final card in widget.cards) _card(card),
                  if (widget.busy && widget.enabled && !widget.paused)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 2,
                      ),
                      child: Text(
                        _t('正在整理这一步的知识点…', 'Preparing a useful takeaway…'),
                        style: _style(size: 12, muted: true),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!_following)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: _LearningButton(
                key: const Key('learning-follow-latest'),
                label: _unread == 0
                    ? _t('跟随最新', 'Follow latest')
                    : _t(
                        '$_unread 条新讲解 · 跟随最新',
                        '$_unread new · Follow latest',
                      ),
                secondary: true,
                expand: true,
                onPressed: _followLatest,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
            child: Text(
              _t(
                '基于可见操作的讲解，不是 Agent 的内部思考。',
                'Explanations of visible work, not the agent’s private reasoning.',
              ),
              style: _style(size: 10, muted: true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Codicons.book, size: 26, color: AppColors.textMuted),
        const SizedBox(height: 14),
        Text(
          widget.enabled
              ? _t('等一个值得学的瞬间', 'Waiting for a useful moment')
              : _t('把等待，变成一点收获', 'Turn waiting into a small discovery'),
          style: _style(size: 15, strong: true),
        ),
        const SizedBox(height: 8),
        Text(
          widget.enabled
              ? _t(
                  '下一次有实质性操作时，讲解会出现在这里。不追逐每个 token，只留下值得学的知识点。',
                  'The next meaningful completed operation will appear here. Not every token—just something worth learning.',
                )
              : _t(
                  '根据已完成的操作，解释改了什么、有什么值得学。先选择独立讲解模型；确认之前不会发送上下文。',
                  'Discover what changed and what you can learn from completed work. Choose a separate explanation model first; no context is sent before you confirm.',
                ),
          style: _style(muted: true),
        ),
        if (!widget.enabled) ...[
          const SizedBox(height: 16),
          _LearningButton(
            label: _t('配置讲解模型', 'Choose explanation model'),
            onPressed: widget.onConfigure,
          ),
        ],
      ],
    ),
  );

  Widget _notice(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: _style(size: 12, muted: true)),
  );

  Widget _recapCard() {
    final concepts = widget.cards.reversed
        .map((card) => card.concept.trim())
        .where((text) => text.isNotEmpty)
        .toSet()
        .take(3)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LearningButton(
            key: const Key('learning-recap'),
            label: _t(
              '这轮记住 ${concepts.length} 点',
              '${concepts.length} takeaways to keep',
            ),
            icon: _recap ? Codicons.chevronUp : Codicons.chevronDown,
            secondary: true,
            expand: true,
            onPressed: () => setState(() {
              _recap = !_recap;
              _following = false;
            }),
          ),
          if (_recap)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < concepts.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${i + 1}. ${concepts[i]}',
                        style: _style(size: 12),
                      ),
                    ),
                  Text(
                    _t(
                      '摘自已有卡片 · 不额外调用模型',
                      'From existing cards · No extra model request',
                    ),
                    style: _style(size: 10, muted: true),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _card(LearningCard card) {
    final expanded = _expanded.contains(card.id);
    return Container(
      key: Key('learning-card-${card.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.code,
        border: Border.all(color: AppColors.partBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            card.title,
            maxLines: expanded ? null : 2,
            overflow: expanded ? null : TextOverflow.ellipsis,
            style: _style(strong: true),
          ),
          const SizedBox(height: 7),
          Text(
            card.summary,
            maxLines: expanded ? null : 2,
            overflow: expanded ? null : TextOverflow.ellipsis,
            style: _style(),
          ),
          if (card.concept.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_t('知识点', 'Takeaway'), style: _style(size: 10, muted: true)),
            const SizedBox(height: 3),
            Text(
              card.concept,
              maxLines: expanded ? null : 3,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: _style(size: 12),
            ),
          ],
          if (expanded) ...[
            _detail(
              _t('可能的原因', 'Possible rationale'),
              card.why.isEmpty
                  ? _t(
                      '现有上下文不足，暂不判断原因。',
                      'There is not enough context to infer a reason.',
                    )
                  : card.why,
            ),
            if (card.tradeoff case final tradeoff?)
              _detail(_t('权衡', 'Tradeoff'), tradeoff),
            if (card.example case final example?)
              _detail(_t('举个例子', 'Example'), example),
            for (final evidence in card.evidence) ...[
              const SizedBox(height: 10),
              Text(
                _t('依据 · ${evidence.label}', 'Evidence · ${evidence.label}'),
                style: _style(size: 11, muted: true),
              ),
              const SizedBox(height: 5),
              Text(
                evidence.excerpt.length > 600
                    ? '${evidence.excerpt.substring(0, 600)}…'
                    : evidence.excerpt,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: _style(size: 12, muted: true),
              ),
              if (widget.onOpenEvidence != null && evidence.path != null) ...[
                const SizedBox(height: 5),
                _LearningButton(
                  label: _t('只读查看当前文件', 'View current file · Read-only'),
                  secondary: true,
                  onPressed: () => widget.onOpenEvidence!(evidence),
                ),
              ],
            ],
          ],
          const SizedBox(height: 10),
          _LearningButton(
            key: Key('learning-expand-${card.id}'),
            label: expanded
                ? _t('收起', 'Less')
                : _t('为什么 · 深入一点', 'Why · A little deeper'),
            icon: expanded ? Codicons.chevronUp : Codicons.chevronDown,
            secondary: true,
            onPressed: () => setState(() {
              if (expanded) {
                _expanded.remove(card.id);
              } else {
                _expanded.add(card.id);
                _following = false;
              }
            }),
          ),
        ],
      ),
    );
  }

  Widget _detail(String title, String content) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: _style(size: 10, muted: true)),
        const SizedBox(height: 4),
        Text(content, style: _style(size: 12)),
      ],
    ),
  );
}

/// Adds keyboard activation and a visible focus ring to the native button
/// without changing the shared workbench control's existing behavior.
class _LearningButton extends StatefulWidget {
  const _LearningButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.secondary = false,
    this.expand = false,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool secondary, expand;
  @override
  State<_LearningButton> createState() => _LearningButtonState();
}

class _LearningButtonState extends State<_LearningButton> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (value) => setState(() => _focused = value),
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
          color: _focused ? AppColors.accent : const Color(0x00000000),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: IdeButton(
          label: widget.label,
          onPressed: widget.onPressed,
          icon: widget.icon,
          secondary: widget.secondary,
          expand: widget.expand,
        ),
      ),
    ),
  );
}
