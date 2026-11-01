import 'dart:async';

import 'package:baocode/learning/learning_preferences.dart';
import 'package:baocode/learning/learning_settings_dialog.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'learning_visual_fonts.dart';

void main() {
  learningWidgetTest('turn off stops locally before a failed preference save', (
    tester,
  ) async {
    final providers = ModelProviders.memory(
      providers: const [
        ModelProvider(
          id: 'synthetic',
          name: 'Synthetic',
          models: [ProviderModel(id: 'teacher')],
        ),
      ],
    );
    final values = <String, Object?>{};
    var failWrites = false;
    var stopped = false;
    final preferences = LearningPreferences(
      read: (key) => values[key],
      write: (key, value) async {
        if (failWrites) {
          expect(stopped, isTrue);
          throw StateError('Synthetic save failure');
        }
        values[key] = value;
      },
      providers: providers,
    );
    addTearDown(preferences.dispose);
    addTearDown(providers.dispose);
    await preferences.configure(modelRef: '@synthetic/teacher', consent: true);
    failWrites = true;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    unawaited(
      showLearningSettingsDialog(
        context,
        preferences: preferences,
        providers: providers,
        onDisable: () => stopped = true,
        anchor: const Rect.fromLTWH(20, 20, 1, 1),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn learning off'));
    await tester.pumpAndSettle();
    expect(stopped, isTrue);
    expect(find.text('Could not save learning settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
