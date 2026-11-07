import 'package:flutter/widgets.dart';

import '../theme/workbench_theme.dart' show themeColors;
import 'brand_logos.dart';

/// Session identity, separate from provider logos and activity indicators.
/// Unknown kernels retain their own logo rather than borrowing a brand.
class AgentBrandMark extends StatelessWidget {
  const AgentBrandMark(this.logo, {super.key, this.color});

  final String logo;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (logo != 'claudecode' && logo != 'codex') {
      return BrandLogo(logo, size: 12, color: color);
    }
    final colors = themeColors;
    final claude = logo == 'claudecode';
    final dark = colors.dark;
    final foreground = colors.highContrast
        ? (dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000))
        : claude
        ? (dark ? const Color(0xFFFFB48F) : const Color(0xFF9D431E))
        : (dark ? const Color(0xFF9ECFFF) : const Color(0xFF225F9F));
    final background = colors.highContrast
        ? (dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF))
        : claude
        ? (dark ? const Color(0xFF422D25) : const Color(0xFFFFEDE3))
        : (dark ? const Color(0xFF20364D) : const Color(0xFFE5F0FF));
    return Semantics(
      label: claude ? 'Claude Code' : 'Codex',
      image: true,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 18,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: foreground.withValues(
                  alpha: colors.highContrast ? 1 : .24,
                ),
              ),
            ),
            child: Center(
              child: claude
                  ? BrandLogo('claude', size: 12, color: foreground)
                  : CustomPaint(
                      size: const Size.square(12),
                      painter: _TerminalMarkPainter(foreground),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An app-owned terminal glyph, not the dense provider mark used elsewhere.
class _TerminalMarkPainter extends CustomPainter {
  const _TerminalMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 12, size.height / 12);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(2, 3)
        ..lineTo(5, 6)
        ..lineTo(2, 9),
      paint,
    );
    canvas.drawLine(const Offset(7, 9), const Offset(10, 9), paint);
  }

  @override
  bool shouldRepaint(_TerminalMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
