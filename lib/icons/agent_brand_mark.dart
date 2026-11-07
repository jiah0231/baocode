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
              // Codex sessions use the recognizable ChatGPT/OpenAI knot,
              // not a terminal prompt. The asset has a little more inset.
              child: BrandLogo(
                claude ? 'claude' : 'openai',
                size: claude ? 12 : 14,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
