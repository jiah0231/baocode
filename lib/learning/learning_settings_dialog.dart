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
  required VoidCallback onDisable,
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
        '在设置 → 模型中添加并启用提供商和聊天模型，再回来选择。此独立模型同时用于知识气泡和过程讲述；当前没有可用模型，不会发送上下文或用本地模板冒充模型讲述。',
        'Add and enable a provider and chat model in Settings → Models, then return here. This independent model supplies both knowledge bubbles and the work narrative. No model is currently available: no context is sent and no local template is presented as a model narrative.',
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
            t('从容 · 最快每24秒', 'Calm · At most once every 24s'),
            checked: preferences.pace == LearningPace.calm,
            onSelected: () => pace = LearningPace.calm,
          ),
          IdeMenuAction(
            t('均衡 · 最快每12秒', 'Balanced · At most once every 12s'),
            checked: preferences.pace == LearningPace.balanced,
            onSelected: () => pace = LearningPace.balanced,
          ),
        ],
      ),
      if (preferences.enabled) ...[
        const IdeMenuSeparator(),
        IdeMenuAction(
          t('关闭讲解', 'Turn learning off'),
          onSelected: () {
            // Stop/cancel and clear locally before the preference write; a
            // failed save must not leave explanation requests running.
            onDisable();
            disable = true;
          },
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
        message: t('开启讲解与过程讲述？', 'Enable explanations and work narrative?'),
        detail: t(
          '独立模型：${choice.label}\n\n此模型同时生成操作旁的知识讲解气泡，以及右侧用自然语言串联阶段与进展的过程讲述；后者不是本地工具列表。两者共用请求频率和本次会话预算，可能产生额外模型费用。\n\n仅发送当前项目中限量、尽力脱敏的操作事实、代码、diff 和工具输出摘录；不发送完整对话、环境或 Agent 内部思考。自动脱敏不能保证识别所有敏感内容，请仅在允许向此提供商分享时开启。\n\n讲述基于可见证据，推测会明确标注，不代表 Agent 隐藏的真实思考。两者均只读、无工具、不修改代码，暂停或关闭会一起停止。旧版气泡授权不会自动开启过程讲述。',
          'Independent model: ${choice.label}\n\nThis model generates both inline explanation bubbles and a model-written work narrative connecting stages and progress on the right—not a local tool list. Both share the request pace and session budget; additional model costs may apply.\n\nOnly bounded, best-effort-redacted operation facts, code, diffs and tool excerpts from this project are sent. No full transcript, environment or private agent reasoning is sent. Redaction is imperfect; enable only if you may share this context with this provider.\n\nNarratives use observable evidence and label speculation, not hidden reasoning. Both are read-only with no tools or code changes. Pause/off stops both. Earlier bubble-only consent does not enable the narrative.',
        ),
        buttons: [t('同意并开启两项', 'Agree and enable both')],
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
