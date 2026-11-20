import 'package:bao_editor/monaco/vs/platform/theme/common/theme.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';

import 'pebrel_theme.dart';
import 'workbench_colors.dart';
import 'workbench_theme_initial_colors.dart';

final _defaultColors = WorkbenchColors(
  ColorThemeData.createUnloadedThemeForThemeType(
    ColorScheme.dark,
    colorThemeDarkInitialColors,
  ),
);

WorkbenchColors _colors = _defaultColors;
PebrelThemeDefinition? _pebrel;
bool _windowsFonts = false;
int _revision = 0;

WorkbenchColors get themeColors => _colors;
int get renderThemeRevision => _revision;
PebrelThemeDefinition? get renderPebrelTheme => _pebrel;
bool get renderUsesWindowsFonts => _windowsFonts;

// Native translucent window chrome is outside the browser chat surface.
bool get renderWindowBlurEnabled => false;

/// Install the host appearance before rendering a conversation. The font
/// platform is the host's, not inferred from the extension's user agent.
/// The caller is responsible for scheduling a rebuild after a live change.
void installBrowserRenderTheme({
  required bool windowsFonts,
  WorkbenchColors? colors,
  PebrelThemeDefinition? pebrel,
}) {
  _colors = colors ?? _defaultColors;
  _pebrel = pebrel;
  _windowsFonts = windowsFonts;
  _revision++;
}
