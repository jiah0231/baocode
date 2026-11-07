// Pebrel theme adapter, adapted 2026-11-04 from Kuddev/pebrel.
// GPL-3.0-or-later. See assets/pebrel/NOTICE.md and LICENSE.
import 'dart:convert';

import 'pebrel_render_palette.dart';

/// A lossless app-owned snapshot, separate from the MIT editor's theme model.
/// Geometry, typography, effects and unknown future fields survive round trips;
/// rendering overrides do not overwrite the user's layout or font settings.
class PebrelThemeDefinition {
  PebrelThemeDefinition._(this._document, this._source);

  factory PebrelThemeDefinition.fromJson(Map<String, dynamic> document) {
    final copy = jsonDecode(jsonEncode(document)) as Map<String, dynamic>;
    final resolved = _normalize(copy);
    _validate(resolved);
    return PebrelThemeDefinition._(resolved, copy);
  }

  final Map<String, dynamic> _document;
  final Map<String, dynamic> _source;
  String get name => _document['name'] as String;
  String get base => _document['base'] as String;
  bool get isLight => _document['appearance'] == 'light';
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_source)) as Map<String, dynamic>;

  Map<String, dynamic> get terminal => Map<String, dynamic>.from(
    jsonDecode(jsonEncode(_document['terminal'])) as Map,
  );

  Map<String, dynamic> get typography =>
      jsonDecode(jsonEncode(_document['typography'])) as Map<String, dynamic>;

  List<String> get indexedColors =>
      List<String>.from((_document['terminal'] as Map)['palette'] as List);

  Map<String, String> get uiColors {
    final ui = _document['ui'] as Map;
    if (ui['derive'] != true) {
      return {for (final key in _uiKeys) key: ui[key] as String};
    }
    final term = _document['terminal'] as Map;
    final palette = indexedColors;
    final background = term['background'] as String;
    final foreground = term['foreground'] as String;
    return {
      'shell': _mix(background, isLight ? '#000000' : '#FFFFFF', .06),
      'background': background,
      'foreground': foreground,
      'muted': palette[8],
      'accent':
          (term['cursor'] ?? term['cursor_stroke'] ?? palette[14]) as String,
      'selection':
          (term['selection_background'] ??
                  _mix(background, foreground, isLight ? .13 : .18))
              as String,
      'line': palette[8],
      'frame': palette[8],
      'error': palette[9],
      'success': palette[10],
      'warning': palette[11],
      'info': palette[14],
    };
  }

  /// VS Code-compatible rendering data. Original data is never replaced by this
  /// intentionally narrower projection. No font or geometry override is applied.
  Map<String, dynamic> toColorThemeJson() {
    final original = uiColors;
    final u = pebrelRenderPalette(original, indexedColors, light: isLight);
    final t = terminal;
    final fg = u['foreground']!;
    final bg = u['background']!;
    final shell = u['shell']!;
    final selected = u['selected']!;
    final line = u['line']!;
    final accent = u['accent']!;
    final muted = u['muted']!;
    final colors = <String, String>{};
    void put(String value, String keys) {
      for (final key in keys.split(' ')) {
        colors[key] = value;
      }
    }

    put(
      shell,
      'sideBar.background activityBar.background titleBar.activeBackground titleBar.inactiveBackground editorGroupHeader.tabsBackground statusBar.background statusBar.noFolderBackground',
    );
    put(
      bg,
      'editor.background panel.background input.background tab.activeBackground settings.textInputBackground',
    );
    put(
      fg,
      'foreground editor.foreground sideBar.foreground input.foreground dropdown.foreground menu.foreground quickInput.foreground list.activeSelectionForeground list.inactiveSelectionForeground list.hoverForeground tab.activeForeground statusBar.foreground titleBar.activeForeground activityBar.foreground button.secondaryForeground quickInputList.focusForeground',
    );
    put(
      muted,
      'descriptionForeground icon.foreground input.placeholderForeground tab.inactiveForeground activityBar.inactiveForeground titleBar.inactiveForeground editorLineNumber.foreground',
    );
    put(
      line,
      'panel.border sideBar.border activityBar.border titleBar.border editorGroup.border menu.border tab.border surface.border',
    );
    put(u['controlBorder']!, 'input.border dropdown.border checkbox.border');
    put(
      accent,
      'button.background progressBar.background badge.background activityBarBadge.background editorCursor.foreground list.highlightForeground tab.activeBorder inputOption.activeForeground',
    );
    put(
      u['buttonText']!,
      'button.foreground badge.foreground activityBarBadge.foreground',
    );
    put(u['buttonHover']!, 'button.hoverBackground');
    put(u['focus']!, 'focusBorder list.focusOutline inputOption.activeBorder');
    put(u['link']!, 'textLink.foreground textLink.activeForeground');
    put(u['heading']!, 'settings.headerForeground');
    put(u['disabled']!, 'disabledForeground');
    put(u['surface']!, 'editorWidget.background button.secondaryBackground');
    put(
      u['raised']!,
      'menu.background dropdown.background dropdown.listBackground quickInput.background settings.dropdownBackground',
    );
    put(u['composer']!, 'agentsChatInput.background chat.requestBackground');
    put(
      u['hover']!,
      'list.hoverBackground toolbar.hoverBackground button.secondaryHoverBackground',
    );
    put(u['inlineCode']!, 'textPreformat.foreground');
    put(u['codeFill']!, 'textPreformat.background');
    put(line, 'chat.requestBorder');
    put(
      selected,
      'list.activeSelectionBackground list.inactiveSelectionBackground list.focusBackground quickInputList.focusBackground inputOption.activeBackground editor.selectionBackground',
    );
    put(
      u['error']!,
      'errorForeground editorError.foreground gitDecoration.deletedResourceForeground inputValidation.errorBorder list.errorForeground chat.linesRemovedForeground',
    );
    put(
      u['success']!,
      'gitDecoration.addedResourceForeground editorGutter.addedBackground chat.linesAddedForeground',
    );
    put(
      u['warning']!,
      'editorWarning.foreground gitDecoration.modifiedResourceForeground inputValidation.warningBorder list.warningForeground',
    );
    put(u['info']!, 'editorInfo.foreground inputValidation.infoBorder');
    put(
      u['addedFill']!,
      'diffEditor.insertedLineBackground diffEditor.insertedTextBackground',
    );
    put(
      u['removedFill']!,
      'diffEditor.removedLineBackground diffEditor.removedTextBackground',
    );
    // Keep original tokens for cached snapshots and independent source previews.
    for (final entry in original.entries) {
      colors['pebrel.${entry.key}'] = entry.value;
    }
    for (final entry in u.entries) {
      colors['pebrel.render.${entry.key}'] = entry.value;
    }
    colors['terminal.background'] = t['background'] as String;
    colors['terminal.foreground'] = t['foreground'] as String;
    const terminalKeys = {
      'cursor': 'terminalCursor.foreground',
      'cursor_text': 'terminalCursor.background',
      'selection_foreground': 'terminal.selectionForeground',
      'selection_background': 'terminal.selectionBackground',
    };
    for (final entry in terminalKeys.entries) {
      if (t[entry.key] case final String value) colors[entry.value] = value;
    }
    const ansi = [
      'Black',
      'Red',
      'Green',
      'Yellow',
      'Blue',
      'Magenta',
      'Cyan',
      'White',
      'BrightBlack',
      'BrightRed',
      'BrightGreen',
      'BrightYellow',
      'BrightBlue',
      'BrightMagenta',
      'BrightCyan',
      'BrightWhite',
    ];
    for (var i = 0; i < ansi.length; i++) {
      colors['terminal.ansi${ansi[i]}'] = indexedColors[i];
    }
    // Syntax colors are an explicit adaptation, not copied from a Pebrel editor.
    return {
      'name': name,
      'type': isLight ? 'light' : 'dark',
      'colors': colors,
      'semanticHighlighting': true,
      'tokenColors': [
        {
          'settings': {'foreground': fg, 'background': bg},
        },
        {
          'scope': 'comment',
          'settings': {'foreground': muted},
        },
        {
          'scope': 'string',
          'settings': {'foreground': u['string']},
        },
        {
          'scope': 'keyword, storage',
          'settings': {'foreground': u['keyword']},
        },
        {
          'scope': 'constant.numeric, constant.language',
          'settings': {'foreground': u['number']},
        },
        {
          'scope': 'entity.name.function, support.function',
          'settings': {'foreground': u['function']},
        },
        {
          'scope': 'entity.name.type, support.type, support.class, entity.other.attribute-name',
          'settings': {'foreground': u['type']},
        },
        {
          'scope': 'variable.other.property, support.variable',
          'settings': {'foreground': u['type']},
        },
        {
          'scope': 'markup.bold',
          'settings': {'foreground': u['emphasis'], 'fontStyle': 'bold'},
        },
        {
          'scope': 'markup.heading',
          'settings': {'foreground': u['heading'], 'fontStyle': 'bold'},
        },
        {
          'scope': 'invalid',
          'settings': {'foreground': u['error']},
        },
      ],
    };
  }

  /// Pebrel schema-v1 JSON uses sixteen ANSI entries plus sparse indexed
  /// colors, different UI names, flat geometry and percentage effects.
  /// Normalize only the rendering copy; toJson retains the untouched document.
  static Map<String, dynamic> _normalize(Map<String, dynamic> source) {
    if (!source.containsKey('schema_version')) return source;
    Never fail(String key) =>
        throw FormatException('Invalid Pebrel document: $key');
    if (source['schema_version'] != 1) fail('unsupported schema_version');
    if (utf8.encode(jsonEncode(source)).length > 256 * 1024) {
      fail('document exceeds 256 KiB');
    }
    for (final key in ['metadata', 'extensions']) {
      if (source.containsKey(key) && source[key] is! Map) fail(key);
    }
    if (source.containsKey('revision') &&
        (source['revision'] is! int || (source['revision'] as int) < 0)) {
      fail('revision');
    }
    Map<String, dynamic> section(String key) {
      final value = source[key];
      if (value is! Map) fail(key);
      return Map<String, dynamic>.from(value);
    }

    final t = section('terminal');
    final ansi = t['palette'];
    if (ansi is! List || ansi.length != 16) {
      fail('terminal.palette must have sixteen colors');
    }
    final palette = <dynamic>[...ansi];
    const levels = [0, 95, 135, 175, 215, 255];
    String hex(List<int> channels) =>
        '#${channels.map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
    for (final r in levels) {
      for (final g in levels) {
        for (final b in levels) {
          palette.add(hex([r, g, b]));
        }
      }
    }
    for (var i = 0; i < 24; i++) {
      palette.add(hex(List.filled(3, 8 + 10 * i)));
    }
    if (t.containsKey('indexed')) {
      final indexed = t['indexed'];
      if (indexed is! Map) fail('terminal.indexed');
      for (final entry in indexed.entries) {
        final index = int.tryParse(entry.key.toString());
        if (index == null || index < 16 || index > 255) {
          fail('terminal.indexed key');
        }
        palette[index] = entry.value;
      }
    }
    String color(dynamic value, {bool alpha = false}) {
      if (value is! String || !RegExp(r'^#[0-9a-fA-F]+$').hasMatch(value)) {
        fail('color');
      }
      final digits = value.substring(1);
      if ((!alpha && digits.length == 3) || (alpha && digits.length == 4)) {
        return '#${digits.split('').map((c) => '$c$c').join().toUpperCase()}';
      }
      if (digits.length != 6 && !(alpha && digits.length == 8)) {
        fail('color length');
      }
      return value.toUpperCase();
    }

    t['palette'] = [for (final entry in palette) color(entry)];
    for (final key in [
      'background',
      'foreground',
      'cursor',
      'cursor_text',
      'cursor_stroke',
      'selection_foreground',
      'selection_background',
    ]) {
      if (t[key] != null) t[key] = color(t[key]);
    }
    final u = section('ui');
    u['shell'] = u['sidebar'];
    u['line'] = u['border'];
    u['selection'] = u['selected'];
    u['error'] = u['danger'];
    u['derive'] ??= true;
    for (final key in _uiKeys) {
      if (u[key] != null) {
        u[key] = color(u[key], alpha: key == 'line' || key == 'selection');
      }
    }
    final line = u['line'];
    if (line is! String || !_rgba.hasMatch(line)) fail('ui.border');
    u['frame'] ??= line.substring(0, 7);
    u['info'] ??= (t['palette'] as List)[14];
    final type = section('typography');
    if (type['enabled'] is! bool || type['ligatures'] is! bool) {
      fail('typography.enabled/ligatures');
    }
    final layout = section('layout');
    for (final key in ['radius', 'gutter', 'divider_width']) {
      if (layout[key] is! num) fail('layout.$key');
    }
    layout['card'] = {
      'radius': layout['radius'],
      'gutter': layout['gutter'],
      'shadow': layout['shadow'] ?? false,
      'divider': layout['divider_width'],
    };
    final effects = section('effects');
    if (effects['material'] != 'solid' && effects['material'] != 'glass') {
      fail('effects.material');
    }
    for (final key in ['opacity', 'background_image_opacity']) {
      if (effects[key] != null) {
        final value = effects[key];
        if (value is! num || !value.isFinite || value < 0 || value > 100) {
          fail('effects.$key');
        }
        effects[key] = value / 100;
      }
    }
    return {
      ...source,
      'base': (source['metadata'] as Map?)?['base'] ?? 'Nord',
      'terminal': t,
      'ui': u,
      'typography': type,
      'layout': layout,
      'effects': effects,
    };
  }

  static const _uiKeys = [
    'shell',
    'background',
    'foreground',
    'muted',
    'accent',
    'selection',
    'line',
    'frame',
    'error',
    'success',
    'warning',
    'info',
  ];
  static final _rgb = RegExp(r'^#[0-9a-fA-F]{6}$');
  static final _rgba = RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$');

  static void _validate(Map<String, dynamic> d) {
    Never fail(String field) =>
        throw FormatException('Invalid Pebrel theme field: $field');
    final name = d['name'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 256 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      fail('name');
    }
    if (d['base'] is! String) fail('base');
    if (d['appearance'] != 'light' && d['appearance'] != 'dark') {
      fail('appearance');
    }
    final terminal = d['terminal'];
    if (terminal is! Map) fail('terminal');
    for (final key in ['background', 'foreground']) {
      if (terminal[key] is! String || !_rgb.hasMatch(terminal[key] as String)) {
        fail('terminal.$key');
      }
    }
    for (final key in [
      'cursor',
      'cursor_text',
      'cursor_stroke',
      'selection_foreground',
      'selection_background',
    ]) {
      if (terminal[key] != null &&
          (terminal[key] is! String ||
              !_rgb.hasMatch(terminal[key] as String))) {
        fail('terminal.$key');
      }
    }
    final palette = terminal['palette'];
    if (palette is! List ||
        palette.length != 256 ||
        palette.any((v) => v is! String || !_rgb.hasMatch(v))) {
      fail('terminal.palette');
    }
    final ui = d['ui'];
    if (ui is! Map || ui['derive'] is! bool) fail('ui');
    for (final key in _uiKeys) {
      final regex = key == 'selection' || key == 'line' ? _rgba : _rgb;
      if (ui[key] is! String || !regex.hasMatch(ui[key] as String)) {
        fail('ui.$key');
      }
    }
    for (final key in ['typography', 'layout', 'effects']) {
      if (d[key] is! Map) fail(key);
    }
    void range(Map map, String key, double lo, double hi) {
      final value = map[key];
      if (value != null &&
          (value is! num || !value.isFinite || value < lo || value > hi)) {
        fail(key);
      }
    }

    final type = d['typography'] as Map;
    range(type, 'font_size', 4, 96);
    range(type, 'ui_font_size', 10, 20);
    range(type, 'line_height', .5, 3);
    range(type, 'letter_spacing', 0, 8);
    range(type, 'font_weight', 100, 900);
    if (type['font_weight'] != null && type['font_weight'] is! int) {
      fail('font_weight');
    }
    for (final key in ['font_family', 'ui_font_family']) {
      final value = type[key];
      if (value != null &&
          (value is! String ||
              value.trim().isEmpty ||
              value.length > 1024 ||
              value.contains(RegExp(r'[\x00-\x1f\x7f]')))) {
        fail('typography.$key');
      }
    }
    if (type['enabled'] != null && type['enabled'] is! bool) {
      fail('typography.enabled');
    }
    if (type['ligatures'] != null && type['ligatures'] is! bool) {
      fail('typography.ligatures');
    }
    final layout = d['layout'] as Map;
    final card = layout['card'];
    if (card != null) {
      if (card is! Map || (card['shadow'] != null && card['shadow'] is! bool)) {
        fail('layout.card');
      }
      range(card, 'radius', 0, 28);
      range(card, 'gutter', 0, 32);
      range(card, 'divider', 0, 4);
    }
    range(layout, 'padding_x', 0, 48);
    range(layout, 'padding_y', 0, 40);
    final effects = d['effects'] as Map;
    range(effects, 'opacity', 0, 1);
    range(effects, 'background_image_opacity', 0, 1);
  }

  static String _mix(String a, String b, double weight) {
    final channels = [
      for (var i = 1; i < 7; i += 2)
        (int.parse(a.substring(i, i + 2), radix: 16) * (1 - weight) +
                int.parse(b.substring(i, i + 2), radix: 16) * weight)
            .round(),
    ];
    return '#${channels.map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
  }
}
