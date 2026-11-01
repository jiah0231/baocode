import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ide/ide_button.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'learning_controller.dart';
import 'narrative_models.dart';
import 'work_trace.dart';

/// Model-written process narrative, with local facts available only as evidence.
/// Missing generation is never replaced by a templated tool-list narrative.
class WorkTracePanel extends StatefulWidget {
  const WorkTracePanel({
    super.key,
    required this.controller,
    this.narrative,
    this.onOpenItem,
    this.onConfigure,
  });
  final WorkTraceController controller;
  final LearningController? narrative;
  final ValueChanged<String>? onOpenItem;
  final VoidCallback? onConfigure;

  @override
  State<WorkTracePanel> createState() => _WorkTracePanelState();
}

class _TraceReading {
  String? turn;
  bool following = true, facts = false;
  final expanded = <String>{};
  int unread = 0;
  double offset = 0;
}

class _WorkTracePanelState extends State<WorkTracePanel> {
  static final _readings = Expando<_TraceReading>();
  late _TraceReading _reading;
  late ScrollController _scroll;
  String _signature = '';
  String _t(String zh, String en) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;
  List<NarrativePhase> get _phases =>
      widget.narrative?.narrativePhases ?? const [];
  String? get _turn =>
      widget.narrative?.narrativeTurnId ?? widget.controller.currentTurnId;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _reading = _readings[widget.controller] ??= _TraceReading();
    if (_reading.turn != _turn) _resetReading();
    _scroll = ScrollController(
      initialScrollOffset: _reading.offset,
      keepScrollOffset: false,
    )..addListener(_savePosition);
    widget.controller.addListener(_changed);
    widget.narrative?.addListener(_changed);
    _signature = _fingerprint();
  }

  void _resetReading() {
    _reading.turn = _turn;
    _reading.following = true;
    _reading.facts = false;
    _reading.expanded.clear();
    _reading.unread = 0;
    _reading.offset = 0;
  }

  String _fingerprint() => _phases
      .map((p) => '${p.id}:${p.title}:${p.summary}:${p.status}')
      .join('|');
  void _savePosition() {
    if (_scroll.hasClients) _reading.offset = _scroll.offset;
  }

  void _detach(WorkTracePanel old) {
    _savePosition();
    old.controller.removeListener(_changed);
    old.narrative?.removeListener(_changed);
    _scroll.removeListener(_savePosition);
    _scroll.dispose();
  }

  @override
  void didUpdateWidget(WorkTracePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.narrative != widget.narrative) {
      _detach(oldWidget);
      _attach();
    }
  }

  void _changed() {
    if (!mounted) return;
    final changedTurn = _reading.turn != _turn;
    if (changedTurn) _resetReading();
    final signature = _fingerprint();
    final changed = signature != _signature;
    _signature = signature;
    _reading.expanded.retainAll(_phases.map((phase) => phase.id));
    if (changed && !_reading.following) _reading.unread++;
    setState(() {});
    if (changedTurn || (changed && _reading.following)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _reading.following) {
          _scroll.jumpTo(changedTurn ? 0 : _scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _detach(widget);
    super.dispose();
  }

  TextStyle _style({
    double size = 12,
    bool muted = false,
    bool strong = false,
  }) => TextStyle(
    fontSize: size,
    height: 1.5,
    color: muted ? AppColors.textMuted : AppColors.text,
    fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
  );

  @override
  Widget build(BuildContext context) {
    final narrative = widget.narrative;
    final phases = _phases;
    final ended = narrative?.narrativeEnded ?? false;
    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t('工作轨迹', 'Work trace'),
                  style: _style(size: 14, strong: true),
                ),
                const SizedBox(height: 4),
                Text(
                  _t(
                    '模型整理的阶段叙述 · 根据可见操作',
                    'Model-written stages · Grounded in visible work',
                  ),
                  style: _style(size: 11, muted: true),
                ),
                if (widget.onConfigure != null) ...[
                  const SizedBox(height: 8),
                  _TraceButton(
                    key: const Key('work-trace-configure'),
                    label: _t('讲解设置', 'Explanation settings'),
                    onPressed: widget.onConfigure!,
                  ),
                ],
              ],
            ),
          ),
          Container(height: 1, color: AppColors.partBorder),
          Expanded(
            child: NotificationListener<UserScrollNotification>(
              onNotification: (event) {
                if (event.direction != ScrollDirection.idle &&
                    _reading.following) {
                  setState(() => _reading.following = false);
                }
                return false;
              },
              child: ListView(
                key: const Key('work-trace-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  if (phases.isEmpty) _empty(),
                  if (phases.isNotEmpty) ...[
                    if (ended)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          _t(
                            '本轮过程 · ${phases.length} 个阶段',
                            'This turn · ${phases.length} stages',
                          ),
                          style: _style(muted: true),
                        ),
                      ),
                    if ((narrative?.narrativeOmittedCount ?? 0) > 0)
                      _notice(
                        _t(
                          '仅依据部分已观察步骤，不代表完整任务历史。',
                          'Based on a bounded subset of observed steps, not the complete task history.',
                        ),
                      ),
                    if (narrative?.enabled != true)
                      _notice(
                        _t(
                          '已关闭生成，保留已有过程。',
                          'Generation is off; existing stages remain.',
                        ),
                      ),
                    if (narrative?.paused == true)
                      _notice(
                        _t(
                          '已暂停，不再发送新上下文。',
                          'Paused. No new context is being sent.',
                        ),
                      ),
                    for (var i = 0; i < phases.length; i++)
                      _phase(phases[i], i),
                  ],
                  if (narrative?.narrativeError != null)
                    _notice(
                      _t(
                        '工作过程暂未更新。可以检查讲解设置；原始操作不受影响。',
                        'The process narrative could not update. Check explanation settings; the original operations are unaffected.',
                      ),
                    ),
                  if (narrative?.budgetReached == true)
                    _notice(
                      _t(
                        '本次模型请求已到上限，暂不生成新的阶段。',
                        'The session request limit is reached; no new stages will be generated.',
                      ),
                    ),
                  if (narrative?.narrativeBusy == true)
                    _notice(_t('正在整理工作过程…', 'Organizing the work process…')),
                  const SizedBox(height: 10),
                  _TraceButton(
                    key: const Key('work-trace-evidence'),
                    label: _reading.facts
                        ? _t('收起原始依据', 'Hide raw evidence')
                        : _t('查看原始依据', 'Show raw evidence'),
                    icon: _reading.facts
                        ? Codicons.chevronUp
                        : Codicons.chevronDown,
                    onPressed: () => setState(() {
                      _reading.facts = !_reading.facts;
                      _reading.following = false;
                    }),
                  ),
                  if (_reading.facts) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        _t(
                          '本地事实记录，不是模型生成的工作过程。',
                          'Local factual records—not a model-written process narrative.',
                        ),
                        style: _style(size: 11, muted: true),
                      ),
                    ),
                    if (widget.controller.entries.isEmpty)
                      _notice(
                        _t(
                          '尚无可展示的操作依据。',
                          'No operation evidence is available yet.',
                        ),
                      ),
                    for (final entry in widget.controller.entries) _fact(entry),
                    if (widget.controller.omittedCount > 0)
                      _notice(
                        _t(
                          '仅保留最近 ${WorkTraceController.maxEntries} 条依据。',
                          'Only the latest ${WorkTraceController.maxEntries} evidence records are retained.',
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (!_reading.following)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: _TraceButton(
                key: const Key('work-trace-follow-latest'),
                label: _reading.unread > 0
                    ? _t('过程有更新 · 跟随最新', 'Process updated · Follow latest')
                    : _t('跟随最新', 'Follow latest'),
                onPressed: () {
                  setState(() {
                    _reading.following = true;
                    _reading.unread = 0;
                  });
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _scroll.hasClients) {
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    }
                  });
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty() {
    final narrative = widget.narrative;
    final explanation = narrative?.enabled != true
        ? _t(
            '请在聊天区的讲解设置中选择模型并确认开启。未配置、已关闭或需要重新确认时，不会生成工作过程。',
            'Choose a model and confirm sharing in the chat’s explanation settings. No process narrative is generated while unconfigured, off, or awaiting renewed consent.',
          )
        : narrative?.paused == true
        ? _t(
            '生成已暂停。恢复后，新的可见操作可以被整理成阶段叙述。',
            'Generation is paused. After resuming, new visible operations can be organized into stages.',
          )
        : _t(
            '有足够的可见操作后，模型会用一两句话整理每个主要阶段。这里不会用工具清单冒充生成结果。',
            'Once there is enough visible work, the model will describe each major stage in one or two sentences. A tool list is never substituted for generated prose.',
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _t('尚未生成工作过程', 'No work process generated yet'),
            style: _style(size: 14, strong: true),
          ),
          const SizedBox(height: 8),
          Text(explanation, style: _style(muted: true)),
        ],
      ),
    );
  }

  Widget _phase(NarrativePhase phase, int index) {
    final expanded = _reading.expanded.contains(phase.id);
    return Container(
      key: ValueKey(('work-trace-phase', phase.id)),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${index + 1}'.padLeft(2, '0'),
                style: _style(size: 11, muted: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(phase.title, style: _style(size: 13, strong: true)),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(phase.summary, style: _style(size: 13)),
          if (phase.status != 'observed') ...[
            const SizedBox(height: 5),
            Text(switch (phase.status) {
              'inProgress' => _t('阶段仍在进行', 'Stage in progress'),
              'failed' => _t('存在失败记录', 'Contains an observed failure'),
              _ => _t('结果尚未确认', 'Outcome not yet confirmed'),
            }, style: _style(size: 10, muted: true)),
          ],
          const SizedBox(height: 9),
          _TraceButton(
            key: Key('work-trace-phase-evidence-${phase.id}'),
            label: expanded
                ? _t('收起依据', 'Hide evidence')
                : _t('查看依据', 'Show evidence'),
            icon: expanded ? Codicons.chevronUp : Codicons.chevronDown,
            onPressed: () => setState(() {
              if (expanded) {
                _reading.expanded.remove(phase.id);
              } else {
                _reading.expanded.add(phase.id);
                _reading.following = false;
              }
            }),
          ),
          if (expanded)
            for (final evidence in phase.evidence) ...[
              const SizedBox(height: 9),
              Text(evidence.label, style: _style(size: 11, muted: true)),
              if (evidence.sourceItemId case final source?)
                if (widget.onOpenItem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: _TraceButton(
                      label: _t('查看原操作', 'View operation'),
                      onPressed: () => widget.onOpenItem!(source),
                    ),
                  ),
            ],
        ],
      ),
    );
  }

  Widget _notice(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text, style: _style(muted: true)),
  );

  Widget _fact(WorkTraceEntry entry) {
    final status = switch (entry.status) {
      WorkTraceStatus.running => _t('进行中', 'Running'),
      WorkTraceStatus.completed => _t('已完成', 'Completed'),
      WorkTraceStatus.failed => _t('失败', 'Failed'),
      WorkTraceStatus.denied => _t('未获允许', 'Denied'),
      WorkTraceStatus.unknown => _t('结果未确认', 'Outcome unconfirmed'),
    };
    return Padding(
      key: ValueKey(('work-trace-entry', entry.id)),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, style: _style(size: 10, muted: true)),
          if (entry.label.isNotEmpty)
            Text(entry.label, style: _style(size: 11, muted: true)),
          if (entry.added != null && entry.removed != null)
            Text(
              '+${entry.added}  −${entry.removed}',
              style: _style(size: 11, muted: true),
            ),
          if (entry.sourceItemId case final source?)
            if (widget.onOpenItem != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: _TraceButton(
                  label: _t('查看原操作', 'View operation'),
                  onPressed: () => widget.onOpenItem!(source),
                ),
              ),
        ],
      ),
    );
  }
}

class _TraceButton extends StatelessWidget {
  const _TraceButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    child: Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      child: Focus(
        child: Builder(
          builder: (context) => DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: Focus.of(context).hasFocus
                    ? AppColors.accent
                    : const Color(0),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: IdeButton(
                label: label,
                onPressed: onPressed,
                icon: icon,
                secondary: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
