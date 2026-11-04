import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/material.dart' as material show ColorScheme;
import 'package:flutter_test/flutter_test.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/window_blur.dart';
import 'package:baocode/theme/workbench_theme.dart';

const _macchiato = {
  'shell': '#1E2030',
  'background': '#24273A',
  'foreground': '#CAD3F5',
  'muted': '#B8C0E0',
  'accent': '#B7BDF8',
  'selection': '#363A4FFF',
  'line': '#494D64FF',
  'frame': '#6E738D',
  'error': '#ED8796',
  'success': '#A6DA95',
  'warning': '#EED49F',
  'info': '#8AADF4',
};

void _install(Map<String, String> tokens) {
  WorkbenchThemeService.instance = WorkbenchThemeService(
    initial: ColorThemeData.createUnloadedThemeForThemeType(
      ColorScheme.dark,
      tokens,
    ),
  );
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final (light, dark) = first > second ? (first, second) : (second, first);
  return (light + .05) / (dark + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkbenchThemeService previous;
  late bool blur;
  setUp(() {
    previous = WorkbenchThemeService.instance;
    blur = WindowBlur.enabled.value;
    WindowBlur.enabled.value = false;
  });
  tearDown(() {
    WorkbenchThemeService.instance = previous;
    WindowBlur.enabled.value = blur;
  });

  test('explicit Pebrel tokens win over incompatible VS Code colors', () {
    _install({
      'editor.background': '#000000',
      'sideBar.background': '#000000',
      'foreground': '#FFFFFF',
      'agentsChatInput.background': '#FF0000',
      'surface.border': '#FFFFFF',
      'focusBorder': '#FF0000',
      for (final entry in _macchiato.entries)
        'pebrel.${entry.key}': entry.value,
    });
    expect(AppColors.background, const Color(0xFF1E2030));
    expect(AppColors.sidebarSurface, AppColors.background);
    expect(AppColors.code, const Color(0xFF24273A));
    expect(AppColors.conversationSurface, AppColors.code);
    expect(AppColors.surface, AppColors.code);
    expect(AppColors.surfaceRaised, AppColors.code);
    expect(AppColors.text, const Color(0xFFCAD3F5));
    expect(AppColors.textPrimary, AppColors.text);
    expect(AppColors.textMuted, const Color(0xFFB8C0E0));
    expect(AppColors.textFaint, AppColors.textMuted);
    expect(AppColors.accent, const Color(0xFFB7BDF8));
    expect(AppColors.bubbleFill, const Color(0xFF363A4F));
    expect(AppColors.hover, AppColors.bubbleFill);
    expect(AppColors.border, const Color(0xFF494D64));
    expect(AppColors.partBorder, AppColors.border);
    expect(AppColors.bubbleBorder(), AppColors.border);
    expect(AppColors.borderStrong, const Color(0xFF6E738D));
    expect(AppColors.bubbleBorder(focused: true), AppColors.borderStrong);
    expect(AppColors.added, const Color(0xFFA6DA95));
    expect(AppColors.removed, const Color(0xFFED8796));
    expect(AppColors.caution, const Color(0xFFEED49F));
  });

  test('Macchiato text, buttons, selections and diffs remain readable', () {
    _install({
      'button.background': _macchiato['accent']!,
      'button.foreground': _macchiato['background']!,
      for (final entry in _macchiato.entries)
        'pebrel.${entry.key}': entry.value,
    });
    for (final surface in [
      AppColors.background,
      AppColors.conversationSurface,
      AppColors.bubbleFill,
      Color.alphaBlend(AppColors.addedBackground, AppColors.code),
      Color.alphaBlend(AppColors.removedBackground, AppColors.code),
    ]) {
      expect(_contrast(AppColors.text, surface), greaterThanOrEqualTo(4.5));
      expect(
        _contrast(AppColors.textMuted, surface),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(AppColors.addedBackground, AppColors.added.withValues(alpha: .12));
    expect(
      AppColors.removedBackground,
      AppColors.removed.withValues(alpha: .12),
    );
    expect(AppColors.textSelection.a, lessThanOrEqualTo(.3));
    final selectedText = Color.alphaBlend(
      AppColors.textSelection,
      AppColors.text,
    );
    final selectedPage = Color.alphaBlend(
      AppColors.textSelection,
      AppColors.code,
    );
    expect(_contrast(selectedText, selectedPage), greaterThanOrEqualTo(4.5));
    final theme = buildAppTheme();
    expect(theme.colorScheme.primary, AppColors.accent);
    expect(theme.colorScheme.onPrimary, AppColors.code);
    expect(
      _contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
    expect(theme.colorScheme.onSurface, AppColors.text);
    expect(theme.textSelectionTheme.selectionColor, AppColors.textSelection);
  });

  test('transparent Pebrel borders and selections are not replaced', () {
    _install({
      'pebrel.line': '#494D6400',
      'pebrel.selection': '#363A4F20',
      'pebrel.background': '#24273A',
    });
    expect(AppColors.partBorder.a, 0);
    expect(AppColors.bubbleBorder().a, 0);
    expect(AppColors.textSelection, const Color(0x20363A4F));
    expect(
      AppColors.bubbleFill,
      Color.alphaBlend(const Color(0x20363A4F), AppColors.code),
    );
  });

  test(
    'themes without Pebrel tokens retain VS Code semantics and Material seed',
    () {
      _install({
        'sideBar.background': '#102030',
        'editor.background': '#203040',
        'editor.foreground': '#DDEEFF',
        'editorWidget.background': '#304050',
        'menu.background': '#405060',
        'panel.border': '#506070',
        'sideBar.border': '#708090',
        'input.border': '#8090A0',
        'agentsChatInput.background': '#10203080',
        'foreground': '#AABBCC',
        'settings.headerForeground': '#BBCCDD',
        'descriptionForeground': '#8899AA',
        'disabledForeground': '#667788',
        'textLink.foreground': '#90A0B0',
        'list.hoverBackground': '#112233',
        'editor.selectionBackground': '#AABBCC40',
        'gitDecoration.addedResourceForeground': '#88CC88',
        'gitDecoration.deletedResourceForeground': '#CC8888',
        'diffEditor.insertedLineBackground': '#00FF0020',
        'diffEditor.removedLineBackground': '#FF000020',
        'editorWarning.foreground': '#CCCC88',
        'button.background': '#789ABC',
      });
      final colors = themeColors;
      final direct = <Color, String>{
        AppColors.background: 'sideBar.background',
        AppColors.code: 'editor.background',
        AppColors.surface: 'editorWidget.background',
        AppColors.surfaceRaised: 'menu.background',
        AppColors.border: 'panel.border',
        AppColors.partBorder: 'sideBar.border',
        AppColors.borderStrong: 'input.border',
        AppColors.text: 'foreground',
        AppColors.textPrimary: 'settings.headerForeground',
        AppColors.textMuted: 'descriptionForeground',
        AppColors.textFaint: 'disabledForeground',
        AppColors.accent: 'textLink.foreground',
        AppColors.hover: 'list.hoverBackground',
        AppColors.added: 'gitDecoration.addedResourceForeground',
        AppColors.removed: 'gitDecoration.deletedResourceForeground',
        AppColors.addedBackground: 'diffEditor.insertedLineBackground',
        AppColors.removedBackground: 'diffEditor.removedLineBackground',
        AppColors.caution: 'editorWarning.foreground',
      };
      for (final entry in direct.entries) {
        expect(entry.key, colors[entry.value], reason: entry.value);
      }
      final fill = Color.alphaBlend(
        colors['agentsChatInput.background'],
        AppColors.code,
      );
      final border = Color.lerp(
        Color.lerp(fill, colors['editor.foreground'].withValues(alpha: 1), .12),
        AppColors.accent.withValues(alpha: 1),
        .03,
      )!;
      expect(AppColors.bubbleFill, fill);
      expect(AppColors.bubbleBorder(), border);
      expect(
        AppColors.bubbleBorder(focused: true),
        Color.lerp(border, AppColors.accent.withValues(alpha: 1), .2),
      );
      expect(
        AppColors.textSelection,
        seeThroughSelection(
          colors['editor.selectionBackground'],
          AppColors.code,
        ),
      );
      expect(
        buildAppTheme().colorScheme,
        material.ColorScheme.fromSeed(
          seedColor: colors['button.background'],
          brightness: Brightness.dark,
          surface: AppColors.surface,
        ),
      );
    },
  );
}
