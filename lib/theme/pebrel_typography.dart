// Pebrel typography adaptation. GPL-3.0-or-later; see assets/pebrel/NOTICE.md.
import 'pebrel_theme.dart';

/// A rendering-only overlay. It never rewrites editor or terminal preferences.
/// The global bundled-font choice is independent of the selected palette.
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

  /// A global family choice only. Sizes always follow BaoCode preferences.
  static const maple = PebrelTypography(
    family: 'Maple Mono Normal NF CN',
    uiFamily: 'Maple Mono Normal NF CN',
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
    bool globalMapleFont = false,
  }) {
    final base = globalMapleFont ? maple : none;
    if (definition == null) return base;
    final values = definition.typography;
    // A document opt-out affects its overrides, not the global font choice.
    if (values['enabled'] == false) return base;
    double? number(String key) => (values[key] as num?)?.toDouble();
    // Old built-in snapshots contain true as a model default, not a user
    // override. They must not silently turn the user's ligatures back on.
    final hasOverride =
        values['enabled'] == true ||
        const [
          'font_family',
          'font_weight',
          'line_height',
          'letter_spacing',
          'ui_font_family',
        ].any((key) => values[key] != null);
    return PebrelTypography(
      family: base.family ?? (values['font_family'] as String?),
      // Retain imported sizes in the lossless document, never apply them.
      weight: values['font_weight'] as int? ?? base.weight,
      lineHeight: number('line_height') ?? base.lineHeight,
      letterSpacing: number('letter_spacing') ?? base.letterSpacing,
      ligatures: hasOverride || values['ligatures'] == false
          ? values['ligatures'] as bool? ?? base.ligatures
          : base.ligatures,
      uiFamily: base.uiFamily ?? (values['ui_font_family'] as String?),
    );
  }
}
