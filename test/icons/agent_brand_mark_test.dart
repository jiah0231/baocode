import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:baocode/icons/agent_brand_mark.dart';
import 'package:baocode/icons/brand_logos.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final (light, dark) = first > second ? (first, second) : (second, first);
  return (light + .05) / (dark + .05);
}

void main() {
  late WorkbenchThemeService previous;
  setUp(() => previous = WorkbenchThemeService.instance);
  tearDown(() => WorkbenchThemeService.instance = previous);

  for (final scheme in ColorScheme.values) {
    for (final logo in ['claudecode', 'codex']) {
      testWidgets('$logo is compact and readable in $scheme', (tester) async {
        WorkbenchThemeService.instance = WorkbenchThemeService(
          initial: ColorThemeData.createUnloadedThemeForThemeType(scheme, {}),
        );
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 100,
                height: 24,
                child: Row(
                  children: [
                    AgentBrandMark(logo),
                    const SizedBox(width: 4),
                    const Flexible(
                      child: Text(
                        'A long session title remains truncated',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(AgentBrandMark)), const Size(18, 18));
        expect(
          find.bySemanticsLabel(logo == 'codex' ? 'Codex' : 'Claude Code'),
          findsOneWidget,
        );
        final tile =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: find.byType(AgentBrandMark),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        final mark = tester.widget<BrandLogo>(find.byType(BrandLogo));
        // Guard the requested ChatGPT knot: codex.svg is also a terminal
        // symbol, so switching to that asset would regress the session mark.
        expect(mark.name, logo == 'codex' ? 'openai' : 'claude');
        expect(mark.size, logo == 'codex' ? 14 : 12);
        final ink = mark.color!;
        expect((tile.border! as Border).top.color.withValues(alpha: 1), ink);
        expect(contrast(ink, tile.color!), greaterThanOrEqualTo(4.5));
        if (themeColors.highContrast) {
          expect(contrast(ink, tile.color!), 21);
          expect((tile.border! as Border).top.color.a, 1);
        }
        semantics.dispose();
      });
    }
  }

  testWidgets('custom kernels keep the original monochrome logo', (
    tester,
  ) async {
    const color = Color(0xFF123456);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: AgentBrandMark('gemini', color: color)),
      ),
    );
    await tester.pumpAndSettle();
    final logo = tester.widget<BrandLogo>(find.byType(BrandLogo));
    expect(logo.name, 'gemini');
    expect(logo.color, color);
    expect(logo.size, 12);
    expect(tester.takeException(), isNull);
  });
}
