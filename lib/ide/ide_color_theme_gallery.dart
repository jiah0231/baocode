// Original BaoCode theme gallery. Artwork is drawn from geometric shapes;
// no third-party imagery is bundled. Font attribution ships with its assets.
import 'dart:async';

import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../settings/user_settings.dart';
import '../settings/pages/application_font_picker.dart';
import '../theme/code_font.dart';
import '../theme/app_theme.dart' show AppFonts;
import '../theme/workbench_theme.dart';
import 'ide_button.dart';
import 'ide_color_theme_picker.dart';
import 'ide_theme_preview_session.dart';

Future<void> showIdeColorThemeGallery(
  BuildContext context,
  IdeColorThemeController themes, {
  Future<String?> Function()? importTheme,
  UserSettings? settings,
}) async {
  final session = IdeThemePreviewSession(
    themes,
    typographyPreset: CodeFont.mapleFont,
    persistTypographyPreset: settings == null
        ? null
        : (enabled) => settings.update(CodeFont.mapleFontSettingKey, enabled),
  );
  try {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: context.l10n.commonDismiss,
      barrierColor: const Color(0x99000000),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, _, _) =>
          IdeColorThemeGallery(session: session, importTheme: importTheme),
    );
  } finally {
    try {
      await session.cancel();
    } finally {
      session.dispose();
    }
  }
}

class IdeColorThemeGallery extends StatefulWidget {
  const IdeColorThemeGallery({
    super.key,
    required this.session,
    this.importTheme,
  });
  final IdeThemePreviewSession session;
  final Future<String?> Function()? importTheme;

  @override
  State<IdeColorThemeGallery> createState() => _IdeColorThemeGalleryState();
}

class _IdeColorThemeGalleryState extends State<IdeColorThemeGallery> {
  bool? _dark;
  bool _closing = false;
  bool _importing = false;
  Object? _error;

  String _text(String english, String chinese) =>
      context.l10n.localeName.startsWith('zh') ? chinese : english;

  Future<void> _close({bool apply = false}) async {
    if (_closing || _importing || widget.session.busy) return;
    setState(() => _closing = true);
    try {
      if (apply) {
        if (!await widget.session.apply()) return;
      } else {
        await widget.session.cancel();
      }
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  Future<void> _import() async {
    if (_importing || _closing) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final id = await widget.importTheme!();
      if (id != null && mounted) {
        setState(() => _dark = null);
        await widget.session.select(id);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final entries = session.themes.colorThemes
          .where((entry) => _dark == null || isDark(entry.type) == _dark)
          .toList();
      final selected = session.themes.colorThemes
          .where((entry) => entry.id == session.selectedId)
          .firstOrNull;
      final colors = themeColors;
      final uiFamily = CodeFont.typography.uiFamily;
      final uiFamilies = uiFamily == null
          ? null
          : CodeFont.parseFamilies(uiFamily);
      final locked = _closing || _importing || session.busy;
      return PopScope(
        canPop: !locked,
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              unawaited(_close());
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 740),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: ColoredBox(
                    color: colors['editorWidget.background'],
                    child: DefaultTextStyle(
                      style: TextStyle(
                        color: colors['foreground'],
                        fontSize: 13,
                        fontFamily: uiFamilies?.first,
                        fontFamilyFallback: uiFamilies == null
                            ? null
                            : [
                                ...uiFamilies.skip(1),
                                ...?Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.fontFamilyFallback,
                              ],
                        decoration: TextDecoration.none,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _text('Make it your space', '让工作空间，更像你'),
                              style: const TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _text(
                                'Preview colors and a font for every theme. Text sizes follow your BaoCode settings.',
                                '预览配色与通用字体，字号沿用 BaoCode 设置；应用后保存，取消恢复。',
                              ),
                              style: TextStyle(
                                color: colors['descriptionForeground'],
                              ),
                            ),
                            const SizedBox(height: 20),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final filter in <(bool?, String)>[
                                  (null, _text('All themes', '全部主题')),
                                  (true, _text('Dark', '深色')),
                                  (false, _text('Light', '浅色')),
                                ])
                                  IdeButton(
                                    label: filter.$2,
                                    secondary: _dark != filter.$1,
                                    onPressed: locked
                                        ? null
                                        : () =>
                                              setState(() => _dark = filter.$1),
                                  ),
                                if (session.typographyPreset != null)
                                  ApplicationFontPicker(
                                    maple: session.typographyEnabled,
                                    onChanged: locked
                                        ? null
                                        : session.setTypographyEnabled,
                                  ),
                                if (widget.importTheme != null)
                                  IdeButton(
                                    label: _text(
                                      '＋ Import Pebrel JSON',
                                      '＋ 导入 Pebrel JSON',
                                    ),
                                    secondary: true,
                                    onPressed: locked ? null : _import,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final grid = GridView.builder(
                                    key: const ValueKey('theme-gallery-grid'),
                                    gridDelegate:
                                        const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 240,
                                          mainAxisExtent: 170,
                                          crossAxisSpacing: 12,
                                          mainAxisSpacing: 12,
                                        ),
                                    itemCount: entries.length,
                                    itemBuilder: (context, index) {
                                      final entry = entries[index];
                                      return _ThemeCard(
                                        entry: entry,
                                        selected:
                                            entry.id == session.selectedId,
                                        onSelect: locked
                                            ? null
                                            : () => unawaited(
                                                session.select(entry.id),
                                              ),
                                      );
                                    },
                                  );
                                  final preview = _ThemePreview(
                                    typographyEnabled:
                                        session.typographyEnabled,
                                    label:
                                        selected?.label ?? session.selectedId,
                                    text: _text,
                                  );
                                  if (constraints.maxWidth < 700) {
                                    return Column(
                                      children: [
                                        SizedBox(height: 140, child: preview),
                                        const SizedBox(height: 12),
                                        Expanded(child: grid),
                                      ],
                                    );
                                  }
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(flex: 6, child: grid),
                                      const SizedBox(width: 22),
                                      Expanded(flex: 4, child: preview),
                                    ],
                                  );
                                },
                              ),
                            ),
                            if ((_error ?? session.error) case final error?)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  '${_text('Could not change theme', '无法切换主题')}: $error',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors['errorForeground'],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _text(
                                      'Apply saves your palette. Imported themes stay in your library.',
                                      '应用后保存配色；导入的主题会保留在主题库。',
                                    ),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors['descriptionForeground'],
                                    ),
                                  ),
                                ),
                                IdeButton(
                                  label: context.l10n.commonCancel,
                                  secondary: true,
                                  onPressed: locked
                                      ? null
                                      : () => unawaited(_close()),
                                ),
                                const SizedBox(width: 8),
                                IdeButton(
                                  label: _text('Apply theme', '应用主题'),
                                  onPressed: locked
                                      ? null
                                      : () => unawaited(_close(apply: true)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ThemeCard extends StatefulWidget {
  const _ThemeCard({
    required this.entry,
    required this.selected,
    this.onSelect,
  });
  final IdeColorThemeEntry entry;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final selected = widget.selected;
    final onSelect = widget.onSelect;
    final dark = isDark(entry.type);
    final definition = WorkbenchThemeService.instance.pebrelTheme(entry.id);
    Color color(String key, int fallback) {
      final value = definition?.uiColors[key];
      return value != null
          ? Color(int.parse(value.substring(1), radix: 16) | 0xff000000)
          : Color(fallback);
    }

    final background = definition == null
        ? themeColors['editorWidget.background']
        : color('background', dark ? 0xff24273a : 0xffeff1f5);
    final accent = definition == null
        ? themeColors['focusBorder']
        : color('accent', dark ? 0xffc6a0f6 : 0xff8839ef);
    return Semantics(
      key: ValueKey('theme-card-${entry.id}'),
      button: true,
      enabled: onSelect != null,
      selected: selected,
      label: entry.label,
      child: FocusableActionDetector(
        enabled: onSelect != null,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        mouseCursor: onSelect == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onSelect?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: onSelect,
          child: Container(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected || _focused
                    ? themeColors['focusBorder']
                    : _hovered
                    ? accent
                    : themeColors['panel.border'],
                width: selected || _focused ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: definition == null
                      ? Center(
                          child: Text(
                            context.l10n.localeName.startsWith('zh')
                                ? '选择以预览'
                                : 'Select to preview',
                            style: TextStyle(
                              color: themeColors['descriptionForeground'],
                            ),
                          ),
                        )
                      : CustomPaint(
                          painter: _PaletteLandscape(
                            background,
                            accent,
                            color('success', 0xffa6da95),
                            color('warning', 0xffeed49f),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.label.replaceFirst('Pebrel ', ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: definition == null
                                ? themeColors['foreground']
                                : color(
                                    'foreground',
                                    dark ? 0xffcad3f5 : 0xff4c4f69,
                                  ),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (selected)
                        Text(
                          '✓',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An original, palette-driven night garden: arch, moon, rolling hills.
class _PaletteLandscape extends CustomPainter {
  const _PaletteLandscape(this.background, this.accent, this.green, this.gold);
  final Color background, accent, green, gold;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final arch = RRect.fromRectAndCorners(
      Rect.fromLTWH(size.width * .18, 8, size.width * .64, size.height * 1.2),
      topLeft: Radius.circular(size.width * .32),
      topRight: Radius.circular(size.width * .32),
    );
    canvas.save();
    canvas.clipRRect(arch);
    canvas.drawRect(
      Offset.zero & size,
      paint
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: .5), background],
        ).createShader(Offset.zero & size),
    );
    paint.shader = null;
    canvas.drawCircle(
      Offset(size.width * .62, size.height * .33),
      13,
      paint..color = gold,
    );
    canvas.drawOval(
      Rect.fromLTWH(
        -size.width * .2,
        size.height * .65,
        size.width,
        size.height,
      ),
      paint..color = accent,
    );
    canvas.drawOval(
      Rect.fromLTWH(
        size.width * .35,
        size.height * .55,
        size.width,
        size.height,
      ),
      paint..color = green,
    );
    canvas.restore();
    for (final x in [.12, .85, .92]) {
      canvas.drawCircle(
        Offset(size.width * x, size.height * (.4 + x / 4)),
        2,
        paint..color = accent.withValues(alpha: .7),
      );
    }
  }

  @override
  bool shouldRepaint(_PaletteLandscape old) =>
      old.background != background ||
      old.accent != accent ||
      old.green != green ||
      old.gold != gold;
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({
    required this.label,
    required this.text,
    required this.typographyEnabled,
  });
  final bool typographyEnabled;
  final String label;
  final String Function(String, String) text;
  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return Container(
      decoration: BoxDecoration(
        color: colors['editor.background'],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors['panel.border']),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: colors['sideBar.background'],
              padding: const EdgeInsets.all(14),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors['foreground'],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text('LIVE PREVIEW', '实时预览'),
                      style: TextStyle(
                        color: colors['descriptionForeground'],
                        fontSize: 10,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      typographyEnabled
                          ? text(
                              'Maple Mono · all themes',
                              'Maple Mono · 所有主题通用',
                            )
                          : text('Using your existing fonts', '沿用现有字体设置'),
                      key: const ValueKey('application-font-status'),
                      style: TextStyle(
                        color: colors['foreground'],
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${text('Font fallback stack', '字体候选列表')}: '
                      '${CodeFont.effectiveFamilies.join(', ')}'
                      ' · ${CodeFont.size.value} px\n'
                      '${CodeFont.pebrelFontBundled ? text('Maple Mono Normal NF CN: bundled with the app', 'Maple Mono Normal NF CN：应用内置字体') : text('Maple Mono Normal NF CN: not bundled; a fallback may be used', 'Maple Mono Normal NF CN：尚未内置，可能使用回退字体')}\n'
                      '${text('The font works across all themes. Code size, terminal size and interface zoom keep following BaoCode settings. Other font names are fallback candidates, not proof of installation.', '字体适用于所有主题；代码字号、终端字号与界面缩放均沿用 BaoCode 设置。其他字体名称仅为候选，不表示已在系统安装。')}',
                      key: const ValueKey('application-font-source'),
                      style: TextStyle(
                        color: colors['descriptionForeground'],
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      text(
                        'A little clarity.\nRoom to create.',
                        '清晰一点，\n灵感多一点。',
                      ),
                      style: TextStyle(
                        color: colors['editor.foreground'],
                        fontSize: 25,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors['sideBar.background'],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'const idea = {\n  theme: "${label.replaceFirst('Pebrel ', '')}",\n  ready: true\n};',
                        style: AppFonts.codeStyle(13)
                            .copyWith(color: colors['editor.foreground']),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      text(
                        'Your editor, conversations and terminal share this palette.',
                        '编辑器、对话和终端，共用这套配色。',
                      ),
                      style: TextStyle(
                        color: colors['descriptionForeground'],
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final id in [
                          'focusBorder',
                          'terminal.ansiGreen',
                          'terminal.ansiYellow',
                          'terminal.ansiBlue',
                          'terminal.ansiMagenta',
                        ])
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: colors[id],
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
