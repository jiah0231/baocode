import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/theme/pebrel_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/ide/terminal/terminal_colors.dart';

Map<String, dynamic> snapshot(String base) {
  final catalog =
      jsonDecode(File('assets/pebrel/catalog.json').readAsStringSync()) as Map;
  return Map<String, dynamic>.from(
    (catalog['themes'] as List).firstWhere((e) => e['base'] == base) as Map,
  );
}

class _LegacyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/pebrel/catalog.json') throw FlutterError('Not bundled');
    return ByteData.sublistView(await File(key).readAsBytes());
  }
}

class _Storage implements ColorThemeStorage {
  @override
  String? colorThemeSetting;
  @override
  String? colorThemeData;
  final writes = <String>[];
  @override
  void storeColorTheme({required String setting, String? data}) {
    colorThemeSetting = setting;
    colorThemeData = data;
    writes.add(setting);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy injected bundles keep existing themes available', () async {
    final service = WorkbenchThemeService(bundle: _LegacyBundle());
    await service.initialize();
    await service.setColorTheme('Bao Light');
    expect(service.colorThemeId, 'Bao Light');
    expect(service.colorThemes.map((t) => t.id), contains('Bao Dark'));
  });

  test(
    'all sixteen snapshots retain 256 colors and independent UI/terminal',
    () {
      final catalog = jsonDecode(
        File('assets/pebrel/catalog.json').readAsStringSync(),
      ) as Map;
      final entries = catalog['themes'] as List;
      expect(entries, hasLength(16));
      for (final raw in entries) {
        final theme = PebrelThemeDefinition.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        expect(theme.toJson(), equals(raw));
        expect(theme.indexedColors, hasLength(256));
        expect(
          theme.toColorThemeJson()['type'],
          theme.isLight ? 'light' : 'dark',
        );
      }
      final silver = PebrelThemeDefinition.fromJson(snapshot('SilverLight'));
      expect(silver.terminal['background'], '#FFFFFF');
      expect(silver.terminal['foreground'], '#24292F');
      expect(silver.terminal['cursor'], isNull);
    },
  );

  test(
    'Macchiato exact semantic and bright ANSI colors survive adaptation',
    () {
      final theme = PebrelThemeDefinition.fromJson(
        snapshot('CatppuccinMacchiato'),
      );
      final colors = theme.toColorThemeJson()['colors'] as Map;
      expect(colors['editor.background'], theme.uiColors['background']);
      expect(colors['sideBar.background'], theme.uiColors['shell']);
      expect(colors['terminal.ansiRed'], '#ED8796');
      expect(colors['terminal.ansiBrightRed'], '#EC7486');
      expect(colors['pebrel.selection'], theme.uiColors['selection']);
    },
  );

  test('unknown fields, all effects and custom indexed colors round trip', () {
    final raw = snapshot('CatppuccinMacchiato');
    raw['future'] = {
      'some': ['field', 9],
    };
    (raw['effects'] as Map)['future_effect'] = {'enabled': true};
    ((raw['terminal'] as Map)['palette'] as List)[200] = '#123456';
    (raw['layout'] as Map)['padding_x'] = 22.0;
    final theme = PebrelThemeDefinition.fromJson(raw);
    expect(theme.toJson(), raw);
    final exported = theme.toJson();
    exported['name'] = 'Changed';
    expect(theme.name, isNot('Changed'));
    expect(theme.toColorThemeJson().containsKey('layout'), isFalse);
  });

  test(
    'native schema v1 keeps unknown fields and resolves sparse indexed colors',
    () {
      final raw = snapshot('CatppuccinMacchiato');
      final t = raw['terminal'] as Map;
      final full = List<String>.from(t['palette'] as List);
      t['palette'] = full.take(16).toList();
      t['indexed'] = {'200': '#123456'};
      t['cursor'] = null;
      final ui = raw['ui'] as Map;
      for (final entry in {
        'shell': 'sidebar',
        'selection': 'selected',
        'line': 'border',
        'error': 'danger',
      }.entries) {
        ui[entry.value] = ui.remove(entry.key);
      }
      ui['sidebar'] = '#123';
      final native = <String, dynamic>{
        ...raw,
        'schema_version': 1,
        'revision': 3,
        'metadata': {'base': raw['base'], 'vendor': 'kept'},
        'extensions': {
          'future': {'hello': true},
        },
        'typography': {...raw['typography'] as Map, 'enabled': false},
        'layout': {
          'radius': 0,
          'gutter': 0,
          'shadow': false,
          'divider_width': 1,
        },
        'effects': {
          ...raw['effects'] as Map,
          'material': 'solid',
          'opacity': 85,
        },
      }..remove('base');
      final theme = PebrelThemeDefinition.fromJson(native);
      expect(theme.toJson(), native);
      expect(theme.indexedColors[200], '#123456');
      expect(theme.indexedColors[16], '#000000');
      expect(theme.uiColors['shell'], '#112233');
      expect(theme.terminal['cursor'], isNull);
      expect(
        (theme.toColorThemeJson()['colors'] as Map).containsKey(
          'terminalCursor.foreground',
        ),
        isFalse,
      );
      native['schema_version'] = 2;
      expect(
        () => PebrelThemeDefinition.fromJson(native),
        throwsFormatException,
      );
    },
  );

  test('malformed known values are rejected without losing unknown values', () {
    final raw = snapshot('Nord');
    (raw['terminal'] as Map)['palette'] = ['#FFFFFF'];
    expect(() => PebrelThemeDefinition.fromJson(raw), throwsFormatException);
    final bad = snapshot('Nord');
    (bad['effects'] as Map)['opacity'] = 2;
    expect(() => PebrelThemeDefinition.fromJson(bad), throwsFormatException);
  });

  test('derived UI leaves independent terminal colors unchanged', () {
    final raw = snapshot('Nord');
    (raw['ui'] as Map)['derive'] = true;
    final theme = PebrelThemeDefinition.fromJson(raw);
    expect(theme.uiColors['background'], theme.terminal['background']);
    expect(theme.uiColors['accent'], theme.terminal['cursor']);
    expect(theme.toJson()['terminal'], raw['terminal']);
  });

  test(
    'service keeps old themes, previews without persisting and restores',
    () async {
      final service = WorkbenchThemeService()..restore(setting: 'Bao Dark');
      await service.initialize();
      expect(
        service.colorThemes.map((t) => t.id),
        containsAll([
          'Bao Dark',
          'Bao Light',
          'Pebrel Catppuccin Macchiato',
          'Pebrel Warm Sand',
        ]),
      );
      expect(
        service.colorThemes.where(
          (t) =>
              t.id.startsWith('Pebrel ') && !t.id.startsWith('Pebrel Custom '),
        ),
        hasLength(16),
      );
      await service.setColorTheme('Pebrel Catppuccin Macchiato', preview: true);
      final terminal = TerminalColorTheme.resolve(
        service.colors.get,
        type: service.colors.type,
      );
      expect(terminal.ansi[9].toARGB32(), 0xffec7486);
      await service.setColorTheme('Bao Dark', preview: true);
      expect(service.colorThemeId, 'Bao Dark');
      await service.setColorTheme('Pebrel Catppuccin Macchiato');
      final restored = WorkbenchThemeService()
        ..restore(
          setting: service.colorThemeId,
          data: service.colorTheme.toStorage(),
        );
      expect(
        restored.colors['editor.background'],
        service.colors['editor.background'],
      );
      await restored.initialize();
      expect(restored.colorThemeId, service.colorThemeId);
      await restored.setExtensionThemes([]);
      expect(restored.colorThemeId, service.colorThemeId);
    },
  );
  test(
    'library refresh neither saves nor replaces an active preview',
    () async {
      final service = WorkbenchThemeService()..restore(setting: 'Bao Dark');
      await service.initialize();
      final custom = PebrelThemeDefinition.fromJson(
        snapshot('CatppuccinMacchiato'),
      );
      const id = 'Pebrel Custom 11111111111111111111111111111111';
      await service.setCustomPebrelThemes({id: custom});
      final storage = _Storage();
      service.storage = storage;
      await service.setColorTheme(id);
      expect(storage.writes, [id]);
      storage.writes.clear();
      await service.setCustomPebrelThemes({id: custom});
      expect(storage.writes, isEmpty);
      await service.setColorTheme('Bao Light', preview: true);
      await service.setCustomPebrelThemes({id: custom});
      expect(service.colorThemeId, 'Bao Light');
      expect(storage.colorThemeSetting, id);
      expect(storage.writes, isEmpty);
      await service.setCustomPebrelThemes({});
      expect(storage.writes, hasLength(1));
      expect(storage.colorThemeSetting, isNot(id));
    },
  );
}
