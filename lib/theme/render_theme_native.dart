import '../platform/app_platform.dart';
import 'pebrel_theme.dart';
import 'window_blur.dart';
import 'workbench_theme.dart';
export 'workbench_theme.dart' show themeColors;

int get renderThemeRevision => WorkbenchThemeScope.restyles;

PebrelThemeDefinition? get renderPebrelTheme {
  final service = WorkbenchThemeService.instance;
  return service.pebrelTheme(service.colorThemeId);
}

bool get renderUsesWindowsFonts => AppPlatform.isWindows;
bool get renderWindowBlurEnabled =>
    WindowBlur.available && WindowBlur.enabled.value;
