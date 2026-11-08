import 'dart:async';

import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/translation/translation_selection.dart';
import 'package:baocode/translation/translation_dialog.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final truncated in [false, true]) {
    testWidgets('selection adapter discards context, truncated=$truncated', (
      tester,
    ) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host = context;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(
        translateSelection(
          host,
          QuickAskContext(
            selectedText: 'Chosen words',
            contextText: 'PRIVATE SURROUNDING TEXT',
            sourceLabel: 'private-project-name',
            sessionModel: '@private/session-model',
            truncated: truncated,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dialog = tester.widget<TranslationDialog>(
        find.byType(TranslationDialog),
      );
      expect(dialog.selectedText, truncated ? '' : 'Chosen words');
      expect(dialog.captureStatus, truncated ? 'tooLong' : isNull);
      expect(find.textContaining('PRIVATE SURROUNDING'), findsNothing);
      expect(find.textContaining('private-project-name'), findsNothing);
      await tester.tap(find.widgetWithText(IdeButton, 'Close'));
      await tester.pumpAndSettle();
    });
  }
}
