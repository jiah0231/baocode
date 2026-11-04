import 'dart:convert';
import 'dart:io';

import 'package:baocode/theme/pebrel_theme_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> document([String name = 'My theme']) => {
  'name': name,
  'base': 'BreezeDark',
  'appearance': 'dark',
  'terminal': {
    'background': '#112233',
    'foreground': '#DDEEFF',
    'palette': List.filled(256, '#112233'),
  },
  'ui': {
    'derive': false,
    for (final key in ['shell', 'background', 'foreground', 'muted', 'accent',
      'selection', 'line', 'frame', 'error', 'success', 'warning', 'info'])
      key: '#112233',
  },
  'typography': {'font_size': 14},
  'layout': {},
  'effects': {},
  'future': {'nested': [1, true, null, 'unchanged']},
};

void main() {
  late Directory root;
  late Directory library;
  late PebrelThemeStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pebrel-store-test-');
    library = Directory(p.join(root.path, 'User', 'pebrel-themes'));
    store = PebrelThemeStore(directory: library);
  });
  tearDown(() async => root.delete(recursive: true));

  test('empty load does not create data or change existing settings', () async {
    final settings = File(p.join(root.path, 'settings.json'));
    await settings.writeAsString('{"theme":"existing"}');
    expect(await store.load(), isEmpty);
    expect(await library.exists(), isFalse);
    expect(await settings.readAsString(), '{"theme":"existing"}');
  });

  test('imports losslessly, survives restart and never stores source path', () async {
    final source = File(p.join(root.path, 'private-name.json'));
    await source.writeAsString(jsonEncode(document()));
    final id = await store.importFile(source);
    expect(id, matches(RegExp(r'^Pebrel Custom [0-9a-f]{32}$')));
    final restored = await PebrelThemeStore(directory: library).load();
    expect(restored[id]!.toJson(), document());
    final files = await library.list().toList();
    final snapshots = files.where((f) => f.path.endsWith('.json')).toList();
    expect(snapshots, hasLength(1));
    expect(await File(snapshots.single.path).readAsString(),
      isNot(contains(source.path)));
    expect(files.any((f) => f.path.endsWith('.tmp')), isFalse);
    expect(await source.readAsString(), jsonEncode(document()));
  });

  test('name collision never overwrites and failed import leaves queue usable', () async {
    final id = await store.importJson(jsonEncode(document()));
    await expectLater(store.importJson(jsonEncode(document(' MY THEME '))),
      throwsFormatException);
    expect(store.themes.keys, [id]);
    await store.importJson(jsonEncode(document('Other')));
    expect(await store.load(), hasLength(2));
  });

  test('simultaneous instances serialize collision checks', () async {
    final other = PebrelThemeStore(directory: library);
    final first = store.importJson(jsonEncode(document()));
    final second = other.importJson(jsonEncode(document()));
    final expectation = expectLater(second, throwsFormatException);
    await first;
    await expectation;
    expect(await other.load(), hasLength(1));
  });

  test('invalid size, depth, JSON, model and encoding leave no snapshots', () async {
    expect(() => store.importJson(' ' * (PebrelThemeStore.maxImportBytes + 1)),
      throwsFormatException);
    expect(() => store.importJson('${'[' * 65}0${']' * 65}'),
      throwsFormatException);
    expect(() => store.importJson('[]'), throwsFormatException);
    expect(() => store.importJson('{'), throwsFormatException);
    expect(() => store.importJson('{}'), throwsFormatException);
    final invalid = document()..['terminal'] = {};
    expect(() => store.importJson(jsonEncode(invalid)), throwsFormatException);
    final source = File(p.join(root.path, 'invalid.json'));
    await source.writeAsBytes([0xff, 0xfe]);
    await expectLater(store.importFile(source), throwsFormatException);
    await source.writeAsString('x' * (PebrelThemeStore.maxImportBytes + 1));
    await expectLater(store.importFile(source), throwsFormatException);
    expect(await store.load(), isEmpty);
    expect(await library.exists(), isFalse);
  });

  test('brackets and escapes inside strings do not count as nesting', () async {
    final data = document()..['future'] = {'text': '${'[' * 100}\\"${'}' * 100}'};
    final id = await store.importJson(jsonEncode(data));
    expect((await store.load())[id]!.toJson(), data);
  });

  test('corruption, mismatched identities and interrupted temporary writes isolate', () async {
    final id = await store.importJson(jsonEncode(document()));
    final corrupt = File(p.join(library.path, '${'a' * 32}.json'));
    await corrupt.writeAsString('{partial');
    await File(p.join(library.path, '${'b' * 32}.json')).writeAsString(jsonEncode({
      'version': 1, 'id': '../../settings.json', 'theme': document('Fake'),
    }));
    await File(p.join(library.path, '.interrupted.tmp')).writeAsString('partial');
    await File(p.join(library.path, 'unrelated.json')).writeAsString('unchanged');
    expect((await store.load()).keys, [id]);
    expect(store.warnings, hasLength(2));
    expect(store.resolveSelection('Pebrel Custom ${'a' * 32}', fallback: 'Bao Dark'),
      'Bao Dark');
    expect(await corrupt.readAsString(), '{partial');
    expect(await File(p.join(library.path, 'unrelated.json')).readAsString(), 'unchanged');
  });

  test('delete is scoped, durable and missing identities are safe to repeat', () async {
    final id = await store.importJson(jsonEncode(document()));
    final other = await store.importJson(jsonEncode(document('Keep')));
    await expectLater(store.delete('../settings'), throwsFormatException);
    await expectLater(store.delete('Bao Dark'), throwsFormatException);
    expect(store.resolveSelection(id, fallback: 'Bao Dark'), id);
    await store.delete(id);
    expect(store.resolveSelection(id, fallback: 'Bao Dark'), 'Bao Dark');
    expect(store.resolveSelection('Extension theme', fallback: 'Bao Dark'),
      'Extension theme');
    await store.delete(id);
    expect(store.themes.keys, [other]);
    expect((await PebrelThemeStore(directory: library).load()).keys, [other]);
  });

  test('theme display name cannot control paths', () async {
    final id = await store.importJson(jsonEncode(document('../../settings.json')));
    expect(store.themes[id]!.name, '../../settings.json');
    expect(await File(p.join(root.path, 'settings.json')).exists(), isFalse);
  });

  test('failure to create storage does not publish an in-memory import', () async {
    await File(p.join(root.path, 'User')).writeAsString('not a directory');
    await expectLater(store.importJson(jsonEncode(document())),
      throwsA(isA<FileSystemException>()));
    expect(store.themes, isEmpty);
  });

  test('full library refuses new imports without removing existing snapshots', () async {
    await library.create(recursive: true);
    for (var i = 0; i < PebrelThemeStore.maxThemes; i++) {
      final token = i.toRadixString(16).padLeft(32, '0');
      await File(p.join(library.path, '$token.json')).writeAsString(jsonEncode({
        'version': 1, 'id': 'Pebrel Custom $token', 'theme': document('Theme $i'),
      }));
    }
    await expectLater(store.importJson(jsonEncode(document('Overflow'))),
      throwsFormatException);
    expect(await store.load(), hasLength(PebrelThemeStore.maxThemes));
  });

  test('links are not followed on import, restore or delete', () async {
    if (Platform.isWindows) return; // Symlink privilege is not assumed.
    final source = File(p.join(root.path, 'outside.json'));
    await source.writeAsString(jsonEncode(document()));
    final inputLink = Link(p.join(root.path, 'link.json'));
    await inputLink.create(source.path);
    await expectLater(store.importFile(File(inputLink.path)), throwsFormatException);
    await library.create(recursive: true);
    const token = 'cccccccccccccccccccccccccccccccc';
    await Link(p.join(library.path, '$token.json')).create(source.path);
    expect(await store.load(), isEmpty);
    expect(store.warnings, hasLength(1));
    await expectLater(store.delete('Pebrel Custom $token'), throwsFormatException);
    expect(await source.readAsString(), jsonEncode(document()));
  });
}
