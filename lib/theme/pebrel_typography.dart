// Pebrel typography adaptation. GPL-3.0-or-later; see assets/pebrel/NOTICE.md.
import 'pebrel_theme.dart';

/// A rendering-only overlay. It never rewrites editor or terminal preferences.
/// The screenshot preset is a BaoCode choice, not a property of each palette.
class PebrelTypography {
  const PebrelTypography({
    this.family,
    this.size,
    this.weight,
    this.lineHeight,
    this.letterSpacing,
    this.ligatures,
    this.uiFamily,
    this.uiSize,
  });

  static const none = PebrelTypography();
  static const screenshot = PebrelTypography(
    family: 'Maple Mono Normal NF CN',
    size: 15,
    weight: 400,
    lineHeight: 1.45,
    letterSpacing: 0,
    ligatures: true,
    uiFamily: 'Maple Mono Normal NF CN',
    uiSize: 15,
  );

  final String? family;
  final double? size;
  final int? weight;
  final double? lineHeight;
  final double? letterSpacing;
  final bool? ligatures;
  final String? uiFamily;
  final double? uiSize;

  factory PebrelTypography.resolve(
    PebrelThemeDefinition? definition, {
    bool screenshotPreset = false,
  }) {
    if (definition == null) return none;
    final values = definition.typography;
    // An explicit document opt-out wins even over the optional preset.
    if (values['enabled'] == false) return none;
    final base = screenshotPreset ? screenshot : none;
    double? number(String key) => (values[key] as num?)?.toDouble();
    // Old built-in snapshots contain true as a model default, not a user
    // override. They must not silently turn the user's ligatures back on.
    final hasOverride =
        values['enabled'] == true ||
        const [
          'font_family',
          'font_size',
          'font_weight',
          'line_height',
          'letter_spacing',
          'ui_font_family',
          'ui_font_size',
        ].any((key) => values[key] != null);
    return PebrelTypography(
      family: values['font_family'] as String? ?? base.family,
      size: number('font_size') ?? base.size,
      weight: values['font_weight'] as int? ?? base.weight,
      lineHeight: number('line_height') ?? base.lineHeight,
      letterSpacing: number('letter_spacing') ?? base.letterSpacing,
      ligatures: hasOverride || values['ligatures'] == false
          ? values['ligatures'] as bool? ?? base.ligatures
          : base.ligatures,
      uiFamily: values['ui_font_family'] as String? ?? base.uiFamily,
      uiSize: number('ui_font_size') ?? base.uiSize,
    );
  }
}
