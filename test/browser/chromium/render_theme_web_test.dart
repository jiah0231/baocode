@TestOn('browser')
library;

import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/render_theme.dart';
import 'package:baocode/theme/render_theme_web.dart' as browser_theme;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser chat uses the desktop profile for inline code sizing', () {
    browser_theme.installBrowserRenderTheme(windowsFonts: false);
    final previousRevision = renderThemeRevision;
    final other = AppFonts.uiCodeStyle(12.5);
    expect(other.fontSize, 12.5);

    browser_theme.installBrowserRenderTheme(windowsFonts: true);
    final windows = AppFonts.uiCodeStyle(12.5);
    expect(windows.fontSize, 13.5);
    expect(windows.fontFamilyFallback, [
      ...other.fontFamilyFallback!,
      'Consolas',
      'Cascadia Mono',
      'Microsoft YaHei UI',
      'monospace',
    ]);
    expect(renderThemeRevision, greaterThan(previousRevision));
  });
}
