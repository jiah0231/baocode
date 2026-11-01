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
            dropdownTooltip: t('讲解模型与设置', 'Explanation model and settings'),
            onDropdown: (anchor) =>
                unawaited(scope.configure(context, anchor: anchor)),
          ),
        ),
      ),
    );
    final status = !controller.enabled
        ? null
        : controller.budgetReached
        ? t('本次额度已用完', 'Session limit reached')
        : controller.error != null
        ? t('讲解暂不可用', 'Learning unavailable')
        : null;
    final detail = controller.budgetReached
        ? t(
            '本次会话的讲解请求已到安全上限，不再发送新的讲解请求。已有讲解仍可阅读，主任务不受影响。',
            'This conversation has reached its explanation request limit. No new explanation requests will be sent. Existing lessons remain readable; the working agent is unaffected.',
          )
        : t(
            '未能生成这次讲解，主任务不受影响。可暂停讲解，或通过右侧菜单检查独立模型设置。不会显示提供商的原始错误内容。',
            'This explanation could not be prepared; the working agent is unaffected. Pause learning or check the independent model in the menu. Raw provider errors are not displayed.',
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
