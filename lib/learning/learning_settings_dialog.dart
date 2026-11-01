import 'package:flutter/widgets.dart';

import '../ide/ide_dialog.dart';
import '../ide/ide_menu.dart';
import '../models/model_providers.dart';
import 'learning_backend.dart';
import 'learning_models.dart';
import 'learning_preferences.dart';

/// Reuses the workbench's model picker and confirmation, not the agent's
/// model selection. Merely opening this menu never enables transmission.
Future<void> showLearningSettingsDialog(
  BuildContext context, {
  required LearningPreferences preferences,
  required ModelProviders providers,
  Rect? anchor,
}) async {
  final chinese = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
  String t(String zh, String en) => chinese ? zh : en;
  final choices = LearningBackend.choices(providers);
  if (choices.isEmpty) {
    await showIdeDialog(
      context,
      type: IdeDialogType.info,
      message: t('先添加一个讲解模型', 'Add an explanation model first'),
      detail: t(
        '在设置 → 模型中添加并启用提供商和聊天模型，再回来选择。讲解模型独立于工作 Agent，当前不会发送任何上下文。',
        'Add and enable a provider and chat model in Settings → Models, then return here. The explanation model is independent of your working agent. No context is being sent.',
      ),
      buttons: [t('知道了', 'Got it')],
      cancel: null,
    );
    return;
  }
  final box = context.findRenderObject();
  final location =
      anchor ??
      (box is RenderBox && box.hasSize
          ? box.localToGlobal(Offset.zero) & Size(box.size.width, 32)
          : const Rect.fromLTWH(24, 48, 1, 1));
  LearningModelChoice? picked;
  LearningDepth? depth;
  LearningPace? pace;
  var disable = false;
  await showIdeMenu(
    context,
    anchor: location,
    entries: [
      IdeMenuAction(
        t('独立讲解模型', 'Independent explanation model'),
        enabled: false,
      ),
      for (final choice in choices)
        IdeMenuAction(
          choice.label,
          checked: preferences.enabled && preferences.modelRef == choice.ref,
          onSelected: () => picked = choice,
        ),
      const IdeMenuSeparator(),
      IdeMenuAction(
        t('深度', 'Depth'),
        submenu: [
          IdeMenuAction(
            t('轻读 · 一个知识点', 'Brief · One takeaway'),
            checked: preferences.depth == LearningDepth.brief,
            onSelected: () => depth = LearningDepth.brief,
          ),
          IdeMenuAction(
            t('深入 · 加上权衡与例子', 'Deeper · Tradeoffs and examples'),
            checked: preferences.depth == LearningDepth.detailed,
            onSelected: () => depth = LearningDepth.detailed,
          ),
        ],
      ),
      IdeMenuAction(
        t('节奏', 'Pace'),
        submenu: [
          IdeMenuAction(
            t('从容 · 合并更多步骤', 'Calm · Group more steps'),
            checked: preferences.pace == LearningPace.calm,
            onSelected: () => pace = LearningPace.calm,
          ),
          IdeMenuAction(
            t('均衡 · 及时整理要点', 'Balanced · Timely takeaways'),
            checked: preferences.pace == LearningPace.balanced,
            onSelected: () => pace = LearningPace.balanced,
          ),
        ],
      ),
      if (preferences.enabled) ...[
        const IdeMenuSeparator(),
        IdeMenuAction(
          t('关闭讲解', 'Turn learning off'),
          onSelected: () => disable = true,
        ),
      ],
    ],
  );
  if (!context.mounted) return;
  try {
    if (depth case final value?) await preferences.setDepth(value);
    if (pace case final value?) await preferences.setPace(value);
    if (disable) await preferences.disable();
    if (picked case final choice?) {
      if (!context.mounted) return;
      final result = await showIdeDialog(
        context,
        type: IdeDialogType.info,
        message: t('开启独立讲解？', 'Enable independent explanations?'),
        detail: t(
          '讲解模型：${choice.label}\n\n只发送已完成操作中经过限量、尽力脱敏的代码、diff 或工具输出摘录，不发送完整对话、环境或 Agent 的内部思考。自动脱敏并不保证识别所有敏感内容；请仅在允许向该提供商分享当前项目内容时开启。\n\n请求可能产生额外模型费用。讲解只读，不使用工具、不修改代码；可以随时暂停或关闭。更换提供商或模型需要重新确认。',
          'Explanation model: ${choice.label}\n\nOnly bounded excerpts of completed operations—code, diffs or tool output—with best-effort secret redaction are sent. The full transcript, environment and agent’s private reasoning are not sent. Redaction cannot identify all sensitive content; enable only if you may share this project context with this provider.\n\nRequests may incur additional model costs. Explanations are read-only: no tools or code changes. Pause or turn off at any time. Changing the provider or model requires confirmation again.',
        ),
        buttons: [t('同意并开启讲解', 'Agree and enable explanations')],
      );
      if (result == 0 && context.mounted) {
        await preferences.configure(modelRef: choice.ref, consent: true);
      }
    }
  } on Object {
    if (!context.mounted) return;
    await showIdeDialog(
      context,
      type: IdeDialogType.error,
      message: t('未能保存讲解设置', 'Could not save learning settings'),
      detail: t(
        '请检查所选模型是否仍可用，再试一次。',
        'Check that the selected model is still available, then try again.',
      ),
      buttons: [t('知道了', 'Got it')],
      cancel: null,
    );
  }
}
