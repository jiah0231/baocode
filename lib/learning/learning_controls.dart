import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ide/ide_button.dart';
import '../ide/ide_hover.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'learning_scope.dart';

/// One quiet native control in the chat header/composer. The split menu keeps
/// model/depth/pacing/off controls available without a separate learning feed.
class LearningControls extends StatelessWidget {
  const LearningControls({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = LearningScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final controller = scope.controller;
    final chinese = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    String t(String zh, String en) => chinese ? zh : en;
    final label = !controller.enabled
        ? t('边看边学', 'Learn')
        : controller.paused
        ? t('继续讲解', 'Resume learning')
        : t('暂停讲解', 'Pause learning');
    void activate() {
      if (controller.enabled) {
        scope.togglePause();
      } else {
        unawaited(scope.configure(context));
      }
    }

    final control = Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown):
            _LearningSettingsIntent(),
      },
      child: Actions(
        actions: {
          _LearningSettingsIntent: CallbackAction<_LearningSettingsIntent>(
            onInvoke: (_) {
              unawaited(scope.configure(context));
              return null;
            },
          ),
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              activate();
              return null;
            },
          ),
        },
        child: Focus(
          child: IdeButton(
            key: const Key('learning-controls'),
            label: label,
            icon: !controller.enabled
                ? Codicons.book
                : controller.paused
                ? Codicons.play
                : Codicons.debugPause,
            secondary: true,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            onPressed: activate,
            dropdownTooltip: t(
              '气泡与过程讲述设置',
              'Bubble and work narrative settings',
            ),
            onDropdown: (anchor) =>
                unawaited(scope.configure(context, anchor: anchor)),
          ),
        ),
      ),
    );
    final review = scope.preferences.needsConsentReview;
    final status = review
        ? t('请重新确认分享范围', 'Review expanded sharing')
        : !controller.enabled
        ? null
        : controller.budgetReached
        ? t('本次额度已用完', 'Session limit reached')
        : controller.explanationBudgetReached
        ? t('余量留给工作过程', 'Remaining budget reserved for progress')
        : (controller.error != null || controller.narrativeError != null)
        ? t('讲解暂不可用', 'Learning unavailable')
        : null;
    final detail = review
        ? t(
            '过程讲述现在也由独立模型生成。旧版气泡授权已失效；请打开设置，查看两项功能的上下文分享与费用说明后重新确认。在此之前不会发送新请求。',
            'The work narrative is now model-generated too. Earlier bubble-only consent is no longer sufficient. Open settings to review context sharing and shared costs for both features. No new requests are sent until you confirm.',
          )
        : controller.budgetReached
        ? t(
            '知识气泡和过程讲述共用的本次会话请求已到安全上限，两者都不再发送新请求。已有内容仍可阅读，主任务不受影响。',
            'Knowledge bubbles and the work narrative have reached their shared session request limit. Neither sends new requests. Existing content remains readable; the working agent is unaffected.',
          )
        : controller.explanationBudgetReached
        ? t(
            '本次会话不再生成新气泡；剩余请求专用于阶段叙述与收尾整理。已有内容仍可阅读。',
            'No more bubbles will be generated this session. Remaining requests are reserved for progress narration and its closing summary. Existing content remains readable.',
          )
        : t(
            '这次气泡或过程讲述未能生成，主任务不受影响。暂停会一起停止两者；也可在菜单中检查独立模型设置。不显示提供商的原始错误。',
            'This bubble or work narrative could not be prepared; the working agent is unaffected. Pause stops both, or check the independent model in the menu. Raw provider errors are not displayed.',
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: status == null
          ? control
          : Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 7,
              runSpacing: 4,
              children: [
                IdeHover(
                  message: detail,
                  child: Text(
                    status,
                    key: const Key('learning-control-status'),
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ),
                control,
              ],
            ),
    );
  }
}

class _LearningSettingsIntent extends Intent {
  const _LearningSettingsIntent();
}
