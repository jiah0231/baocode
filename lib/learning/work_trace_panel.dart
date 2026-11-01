import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'work_trace.dart';

/// Local observed facts, visually separate from generated teaching bubbles.
class WorkTracePanel extends StatelessWidget {
  const WorkTracePanel({super.key, required this.controller, this.onOpenItem});

  final WorkTraceController controller;
  final ValueChanged<String>? onOpenItem;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    String t(String chinese, String english) => zh ? chinese : english;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final entries = controller.entries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('工作轨迹', 'Work trace'),
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    t(
                      '本轮的重要操作与文件改动 · 本地记录，不调用模型',
                      'This turn’s operations and file changes · Local, no model',
                    ),
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  if (controller.ended) ...[
                    const SizedBox(height: 6),
                    Text(
                      controller.interrupted
                          ? t('本轮已中断', 'Turn interrupted')
                          : t('本轮已结束', 'Turn ended'),
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.partBorder),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          t(
                            '重要操作发生后，会在这里留下轨迹。\n读文件、搜索与思考不会刷屏。',
                            'Important operations will appear here.\nReads, searches and thoughts stay out of the way.',
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                            height: 1.6,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      key: PageStorageKey((
                        'work-trace',
                        controller.currentTurnId,
                      )),
                      padding: const EdgeInsets.all(12),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => _EntryTile(
                        entry: entries[index],
                        zh: zh,
                        onOpenItem: onOpenItem,
                      ),
                    ),
            ),
            if (controller.omittedCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Text(
                  t(
                    '仅保留最近 ${WorkTraceController.maxEntries} 条重要操作',
                    'Showing the latest ${WorkTraceController.maxEntries} important operations',
                  ),
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.zh, this.onOpenItem});
  final WorkTraceEntry entry;
  final bool zh;
  final ValueChanged<String>? onOpenItem;

  @override
  Widget build(BuildContext context) {
    String t(String chinese, String english) => zh ? chinese : english;
    final kind = switch (entry.kind) {
      WorkTraceKind.command => t('命令', 'Command'),
      WorkTraceKind.task => t('子任务', 'Subtask'),
      WorkTraceKind.tool => t('工具操作', 'Tool operation'),
      WorkTraceKind.file => t('文件改动', 'File change'),
    };
    final status = switch (entry.status) {
      WorkTraceStatus.running => t('进行中', 'Running'),
      WorkTraceStatus.completed => t('已完成', 'Completed'),
      WorkTraceStatus.failed => t('失败', 'Failed'),
      WorkTraceStatus.denied => t('未获允许', 'Denied'),
      WorkTraceStatus.unknown => t('结果未确认', 'Outcome unconfirmed'),
    };
    final icon = switch (entry.kind) {
      WorkTraceKind.command => Icons.terminal_rounded,
      WorkTraceKind.task => Icons.account_tree_outlined,
      WorkTraceKind.tool => Icons.build_outlined,
      WorkTraceKind.file => Icons.description_outlined,
    };
    final source = entry.sourceItemId;
    return Container(
      key: ValueKey(('work-trace-entry', entry.id)),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.partBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: AppColors.textMuted),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '$kind · $status',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (entry.label.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              entry.label,
              style: TextStyle(
                color: AppColors.text,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ],
          if (entry.added != null && entry.removed != null) ...[
            const SizedBox(height: 5),
            Text(
              '+${entry.added}  −${entry.removed}',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
          if (source != null && onOpenItem != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => onOpenItem!(source),
                child: Text(
                  t('查看原操作', 'View operation'),
                  style: TextStyle(color: AppColors.accent, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
