// BaoCode's rendering adaptation of Pebrel palettes. GPL-3.0-or-later.
// Source snapshots and terminal colors remain untouched; see NOTICE.md.
import 'dart:ui';

/// Semantic workbench colors, separate from a theme's lossless source document.
/// A terminal accent can be decorative or monochrome; UI actions and small text
/// need their own contrast, and selection must not look like an idle input.
Map<String, String> pebrelRenderPalette(
  Map<String, String> source,
  List<String> ansi, {
  required bool light,
}) {
  Color color(String key) => _parse(source[key]!);
  final background = color('background');
  final shell = color('shell');
  final foreground = color('foreground');
  final originalAccent = color('accent');
  final channels = [originalAccent.r, originalAccent.g, originalAccent.b]
    ..sort();
  final accentSeed = channels.last - channels.first < .08
      ? color('info')
      : originalAccent;
  final surface = _mix(background, foreground, light ? .025 : .035);
  final raised = _mix(
    background,
    light ? const Color(0xFFFFFFFF) : foreground,
    light ? .5 : .065,
  );
  final composer = _mix(background, accentSeed, light ? .035 : .065);
  final hover = _mix(shell, accentSeed, .065);
  final selected = _mix(shell, accentSeed, light ? .14 : .19);
  final codeFill = _mix(background, _parse(ansi[5]), light ? .055 : .09);
  final addedFill = _mix(background, color('success'), .07);
  final removedFill = _mix(background, color('error'), .07);
  final surfaces = [
    background,
    shell,
    surface,
    raised,
    composer,
    hover,
    selected,
    codeFill,
    addedFill,
    removedFill,
  ];
  Color text(Color seed) => _readable(seed, surfaces);
  final body = text(foreground);
  final accent = text(accentSeed);
  final link = text(color('info'));
  final muted = text(_mix(color('muted'), background, .12));
  final buttonText = _contrast(const Color(0xFFFFFFFF), accent) >= 4.5
      ? const Color(0xFFFFFFFF)
      : const Color(0xFF141824);
  final buttonHover = _readable(_mix(accent, buttonText, .08), [buttonText]);
  final values = <String, Color>{
    'background': background,
    'shell': shell,
    'surface': surface,
    'raised': raised,
    'composer': composer,
    'hover': hover,
    'selected': selected,
    'foreground': body,
    'heading': text(_mix(body, accentSeed, .3)),
    'emphasis': text(_parse(ansi[5])),
    'muted': muted,
    'faint': text(_mix(muted, background, .1)),
    'disabled': _mix(muted, background, .3),
    'accent': accent,
    'link': link,
    'line': Color.alphaBlend(color('line'), background),
    'controlBorder': _readable(color('frame'), [background, composer], 3),
    'focus': _readable(accentSeed, [background, shell, selected], 3),
    'buttonText': buttonText,
    'buttonHover': buttonHover,
    'inlineCode': text(_parse(ansi[6])),
    'codeFill': codeFill,
    'success': text(color('success')),
    'error': text(color('error')),
    'warning': text(color('warning')),
    'info': link,
    'addedFill': addedFill,
    'removedFill': removedFill,
    'keyword': text(_parse(ansi[5])),
    'string': text(_parse(ansi[2])),
    'number': text(_parse(ansi[3])),
    'function': text(_parse(ansi[4])),
    'type': text(_parse(ansi[6])),
  };
  return {for (final entry in values.entries) entry.key: _hex(entry.value)};
}

Color _parse(String hex) {
  final value = int.parse(hex.substring(1), radix: 16);
  return Color(
    hex.length == 9
        ? ((value & 0xFF) << 24) | (value >> 8)
        : 0xFF000000 | value,
  );
}

Color _mix(Color from, Color to, double amount) =>
    Color.lerp(from, to, amount)!.withValues(alpha: 1);

double _contrast(Color foreground, Color background) {
  background = Color(background.toARGB32());
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

/// Smallest change toward black or white meeting every painted background.
/// Test the quantized color, not floating channels that round below the target.
Color _readable(Color seed, List<Color> backgrounds, [double minimum = 4.5]) {
  Color quantized(Color value) => Color(value.toARGB32());
  bool passes(Color value) => backgrounds.every(
    (background) => _contrast(value, background) >= minimum,
  );
  final original = quantized(seed);
  if (passes(original)) return original;
  for (var step = 1; step <= 100; step++) {
    for (final target in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
      final candidate = quantized(_mix(seed, target, step / 100));
      if (passes(candidate)) return candidate;
    }
  }
  // An imported palette can put unrelated light and dark surfaces together.
  // Pick the safer extreme without changing its stored colors.
  double worst(Color value) => backgrounds
      .map((background) => _contrast(value, background))
      .reduce((a, b) => a < b ? a : b);
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  return worst(black) > worst(white) ? black : white;
}

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
