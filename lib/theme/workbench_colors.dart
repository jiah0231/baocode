import 'dart:ui' as ui;

import 'package:bao_editor/monaco/vs/base/common/color.dart' as vs;
import 'package:bao_editor/monaco/vs/platform/theme/common/theme.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';

/// A color theme's colors as widgets read them: what the theme sets, else
/// the color registry's default for its type (`IColorTheme.getColor`).
class WorkbenchColors {
  WorkbenchColors(this.theme);

  final ColorThemeData theme;
  final Map<String, ui.Color?> _colors = {};

  ColorScheme get type => theme.type;
  bool get dark => isDark(type);
  bool get highContrast => isHighContrast(type);

  /// The color [id] names; null when neither the theme nor the registry
  /// gives it one.
  ui.Color? get(String id) => _colors.putIfAbsent(id, () {
    final color = theme.getColor(id);
    return color == null ? null : toFlutterColor(color);
  });

  /// [get], else what the element would inherit upstream: a text color
  /// without one (`sideBar.foreground`, `list.hoverForeground`…) leaves CSS
  /// `color` inherited, ending at the workbench's `foreground`; any other
  /// color (a background, a border) is none, so transparent.
  ui.Color operator [](String id) =>
      get(id) ??
      (id != 'foreground' && id.endsWith('oreground')
          ? get('foreground')
          : null) ??
      const ui.Color(0x00000000);

  /// A VS Code color as Flutter paints it.
  static ui.Color toFlutterColor(vs.Color color) {
    final rgba = color.rgba;
    return ui.Color.fromARGB((rgba.a * 255).round(), rgba.r, rgba.g, rgba.b);
  }
}
