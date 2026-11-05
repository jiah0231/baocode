import 'package:flutter/widgets.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';

/// A font-family choice shared by Appearance and the theme preview. It never
/// changes font sizes, zoom, ligatures, or the user's saved custom font stack.
class ApplicationFontPicker extends StatelessWidget {
  const ApplicationFontPicker({
    super.key,
    required this.maple,
    required this.onChanged,
  });

  final bool maple;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final chinese = context.l10n.localeName.startsWith('zh');
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final value in [false, true])
          Semantics(
            selected: maple == value,
            child: IdeButton(
              key: ValueKey(
                value ? 'application-font-maple' : 'application-font-existing',
              ),
              label: value
                  ? (chinese ? 'Maple Mono（内置）' : 'Maple Mono (bundled)')
                  : (chinese ? '沿用现有字体' : 'Use existing fonts'),
              secondary: maple != value,
              onPressed: onChanged == null ? null : () => onChanged!(value),
            ),
          ),
      ],
    );
  }
}
