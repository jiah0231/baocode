import 'dart:async';

import 'package:flutter/widgets.dart';

import 'learning_backend.dart';
import 'learning_controller.dart';
import 'learning_models.dart';
import 'learning_preferences.dart';
import 'learning_settings_dialog.dart';

/// The visible chat's learning projection. Reading a scope or historical card
/// never observes an operation or starts a model request.
class LearningScope extends InheritedNotifier<LearningController> {
  const LearningScope({
    super.key,
    required LearningController controller,
    required this.preferences,
    required this.modelLabel,
    required super.child,
  }) : super(notifier: controller);

  final LearningPreferences preferences;
  final String? modelLabel;
  LearningController get controller => notifier!;

  /// Exact locally observed source IDs only; neither generated references nor
  /// matching file names can attach a lesson to an unrelated operation.
  LearningCard? cardForItem(String sourceItemId) =>
      controller.cardForItem(sourceItemId);

  static LearningScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LearningScope>();

  static LearningScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'LearningScope needs a LearningSessionBinding.');
    return scope!;
  }

  Future<void> configure(BuildContext context, {Rect? anchor}) =>
      showLearningSettingsDialog(
        context,
        preferences: preferences,
        providers: preferences.providers,
        onDisable: controller.disable,
        anchor: anchor,
      );

  void togglePause() {
    if (controller.enabled) controller.setPaused(!controller.paused);
  }

  void disable() {
    // Cancel before the asynchronous preference write, including a failed save.
    controller.disable();
    unawaited(preferences.disable().catchError((Object _) {}));
  }

  @override
  bool updateShouldNotify(LearningScope oldWidget) =>
      super.updateShouldNotify(oldWidget) ||
      preferences != oldWidget.preferences ||
      modelLabel != oldWidget.modelLabel;
}

String? learningModelLabel(LearningPreferences preferences) =>
    LearningBackend.modelLabel(preferences.modelRef, preferences.providers);
