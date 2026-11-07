import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/widgets/markdown_view.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/pebrel_theme.dart';
import 'package:baocode/theme/workbench_theme.dart' hide ColorScheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Color color(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

double contrast(String foreground, String background) {
  final a = color(foreground).computeLuminance();
  final b = color(background).computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog =
      jsonDecode(File('assets/pebrel/catalog.json').readAsStringSync()) as Map;
  final snapshots = (catalog['themes'] as List).cast<Map<String, dynamic>>();

  for (final snapshot in snapshots) {
    test(
      '${snapshot['name']} separates readable UI roles without changing source',
      () {
        final theme = PebrelThemeDefinition.fromJson(snapshot);
        final rendered = theme.toColorThemeJson();
        final colors = Map<String, String>.from(rendered['colors'] as Map);
        String role(String name) => colors['pebrel.render.$name']!;
        for (final background in [
          'background',
          'shell',
          'surface',
          'raised',
          'composer',
          'hover',
          'selected',
          'codeFill',
          'addedFill',
          'removedFill',
        ]) {
          for (final foreground in [
            'foreground',
            'heading',
            'emphasis',
            'muted',
            'faint',
            'link',
            'accent',
            'inlineCode',
            'success',
            'error',
            'warning',
            'keyword',
            'string',
            'number',
            'function',
            'type',
          ]) {
            expect(
              contrast(role(foreground), role(background)),
              greaterThanOrEqualTo(4.5),
              reason: '${theme.name}: $foreground on $background',
            );
          }
        }
        for (final background in ['background', 'composer']) {
          expect(
            contrast(role('controlBorder'), role(background)),
            greaterThanOrEqualTo(3),
          );
        }
        for (final background in ['background', 'shell', 'selected']) {
          expect(
            contrast(role('focus'), role(background)),
            greaterThanOrEqualTo(3),
          );
        }
        expect(
          contrast(role('buttonText'), role('accent')),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(role('buttonText'), role('buttonHover')),
          greaterThanOrEqualTo(4.5),
        );
        expect({
          role('background'),
          role('composer'),
          role('hover'),
          role('selected'),
        }, hasLength(4));
        expect(role('heading'), isNot(role('foreground')));
        expect(role('emphasis'), isNot(role('foreground')));
        expect(colors['textLink.foreground'], role('link'));
        expect(colors['chat.linesAddedForeground'], role('success'));
        expect(colors['chat.linesRemovedForeground'], role('error'));
        expect(colors['editor.background'], theme.uiColors['background']);
        expect(colors['sideBar.background'], theme.uiColors['shell']);
        expect(colors['terminal.background'], theme.terminal['background']);
        expect(colors['terminal.foreground'], theme.terminal['foreground']);
        const ansi = [
          'Black',
          'Red',
          'Green',
          'Yellow',
          'Blue',
          'Magenta',
          'Cyan',
          'White',
          'BrightBlack',
          'BrightRed',
          'BrightGreen',
          'BrightYellow',
          'BrightBlue',
          'BrightMagenta',
          'BrightCyan',
          'BrightWhite',
        ];
        for (var index = 0; index < ansi.length; index++) {
          expect(
            colors['terminal.ansi${ansi[index]}'],
            theme.indexedColors[index],
          );
        }
        expect(theme.toJson(), snapshot);
        expect(theme.indexedColors, (snapshot['terminal'] as Map)['palette']);
        final rules = (rendered['tokenColors'] as List).cast<Map>();
        expect(
          rules.where(
            (rule) =>
                (rule['scope'] as String? ?? '').contains('entity.name.type'),
          ),
          isNotEmpty,
        );
        expect(
          rules
              .map((rule) => (rule['settings'] as Map)['foreground'])
              .toSet()
              .length,
          greaterThanOrEqualTo(7),
        );
      },
    );
  }

  testWidgets(
    'Pebrel markdown uses independent emphasis and link roles and switching restores old themes',
    (tester) async {
      final service = WorkbenchThemeService.instance;
      await tester.runAsync(() async {
        await service.initialize();
        await service.setColorTheme('Pebrel Silver Light', preview: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const MarkdownView(
              '# Heading\n\nBody **important** [link](https://example.com) `code`',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final spans = <TextSpan>[];
      for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            spans.add(span);
            for (final child in span.children ?? <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        visit(text.text);
      }
      expect(
        spans.any(
          (span) =>
              span.style?.fontWeight == FontWeight.w600 &&
              span.style?.color == AppColors.textEmphasis,
        ),
        isTrue,
      );
      expect(spans.any((span) => span.style?.color == AppColors.link), isTrue);
      expect(AppColors.textEmphasis, isNot(AppColors.text));
      expect(AppColors.textPrimary, isNot(AppColors.text));
      expect(AppColors.bubbleFill, isNot(AppColors.hover));
      expect(
        AppColors.bubbleBorder(focused: true),
        isNot(AppColors.bubbleBorder()),
      );
      await tester.runAsync(
        () => service.setColorTheme('Bao Dark', preview: true),
      );
      expect(AppColors.textEmphasis, AppColors.textPrimary);
      expect(AppColors.link, AppColors.accent);
      expect(tester.takeException(), isNull);
    },
  );
}
