import 'dart:async';

import 'package:baocode/learning/learning_preferences.dart';
import 'package:baocode/learning/learning_settings_dialog.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'learning_visual_fonts.dart';

void main() {
  learningWidgetTest(
    'expanded consent names both model surfaces before any enable',
    (tester) async {
      final providers = ModelProviders.memory(
        providers: const [
          ModelProvider(
            id: 'synthetic',
            name: 'Synthetic',
            baseUrl: 'https://synthetic.invalid',
            models: [ProviderModel(id: 'teacher')],
          ),
        ],
      );
      final values = <String, Object?>{};
      final preferences = LearningPreferences(
        read: (key) => values[key],
        write: (key, value) async {
          values[key] = value;
        },
        providers: providers,
      );
      addTearDown(preferences.dispose);
      addTearDown(providers.dispose);
      await preferences.configure(
        modelRef: '@synthetic/teacher',
        consent: true,
      );
      final old = Map<String, Object?>.from(
        values[LearningPreferences.settingKey] as Map,
      );
      values[LearningPreferences.settingKey] = {...old, 'consentVersion': 1};
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
      Future<void> chooseModel() async {
        unawaited(
          showLearningSettingsDialog(
            context,
            preferences: preferences,
            providers: providers,
            onDisable: () {},
            anchor: const Rect.fromLTWH(20, 20, 1, 1),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Synthetic · teacher'));
        await tester.pumpAndSettle();
      }

      expect(preferences.enabled, isFalse);
      await chooseModel();
      expect(
        find.text('Enable explanations and work narrative?'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'both inline explanation bubbles and a model-written work narrative',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Both share the request pace and session budget'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'No full transcript, environment or private agent reasoning',
        ),
        findsOneWidget,
      );
      expect(preferences.enabled, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(preferences.enabled, isFalse);
      expect(preferences.needsConsentReview, isTrue);
      await chooseModel();
      await tester.tap(find.text('Agree and enable both'));
      await tester.pumpAndSettle();
      expect(preferences.enabled, isTrue);
      expect(preferences.needsConsentReview, isFalse);
      expect(
        (values[LearningPreferences.settingKey] as Map)['consentVersion'],
        LearningPreferences.consentVersion,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  learningWidgetTest('turn off stops locally before a failed preference save', (
    tester,
  ) async {
    final providers = ModelProviders.memory(
      providers: const [
        ModelProvider(
          id: 'synthetic',
          name: 'Synthetic',
          baseUrl: 'https://synthetic.invalid',
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
