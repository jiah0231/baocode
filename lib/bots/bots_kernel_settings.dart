import 'package:flutter/material.dart';

import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_dropdown.dart';
import '../settings/pages/settings_widgets.dart';
import 'bots.dart';

/// Desktop-only backend selection; the mobile v1 bot wire format stays intact.
class BotsKernelSettings extends StatelessWidget {
  const BotsKernelSettings({super.key, required this.bots});

  final Bots bots;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bots,
    builder: (context, _) {
      final l10n = context.l10n;
      return SettingsCard(
        children: [
          SettingsRow(
            label: l10n.botsBackendTitle,
            description: l10n.botsBackendDescription,
          ),
          for (final bot in bots.bots)
            SettingsRow(
              label: bot.name,
              description: !bots.canSwitchKernel(bot)
                  ? l10n.botsBackendBusy
                  : null,
              trailing: SettingsDropdown(
                current: bot.kernel == 'codex' ? 'Codex' : 'Claude Code',
                semanticLabel: '${bot.name}: ${l10n.botsBackendTitle}',
                entries: () => [
                  for (final kernel in bots.workspace.kernels)
                    if (kernel.id == 'codex' || kernel.id == 'claude-code')
                      IdeMenuAction(
                        kernel.label,
                        checked: bot.kernel == kernel.id,
                        enabled: bots.canSwitchKernel(bot),
                        onSelected: () {
                          if (bots.canSwitchKernel(bot)) {
                            bots.setKernel(bot, kernel.id);
                          }
                        },
                      ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
