import 'dart:convert';
import 'dart:io';

import 'package:baocode/remote/remote_host_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('baocode-remote-settings-');
    file = File(p.join(directory.path, 'remote-hosts.json'));
  });
  tearDown(() => directory.deleteSync(recursive: true));

  RemoteHostSettings read() => RemoteHostSettings(file: file.path);

  test('missing or unreadable settings never enable local access', () {
    expect(read().localAccess('new-host'), isFalse);
    expect(file.existsSync(), isFalse);
    for (final source in ['{}', '{invalid', '[]', 'null']) {
      file.writeAsStringSync(source);
      final settings = read();
      expect(settings.localAccess('new-host'), isFalse);
      expect(settings.runsWithoutAsking('new-host'), isFalse);
      expect(file.readAsStringSync(), source);
    }
  });

  test('old missing, false and invalid grants remain disabled on upgrade', () {
    file.writeAsStringSync(
      jsonEncode({
        'empty': <String, Object?>{},
        'denied': {'localAccess': false},
        'null': {'localAccess': null},
        'string': {'localAccess': 'true'},
        'number': {'localAccess': 1},
        'orphan': {'runsWithoutAsking': true},
        'forward-only': {
          'forwards': [
            {'direction': 'toRemote', 'port': 8080},
          ],
        },
      }),
    );
    final before = file.readAsStringSync();
    final settings = read();
    const denied = [
      'empty',
      'denied',
      'null',
      'string',
      'number',
      'orphan',
      'forward-only',
      'unknown',
    ];
    for (final host in denied) {
      expect(settings.localAccess(host), isFalse, reason: host);
      expect(settings.runsWithoutAsking(host), isFalse, reason: host);
    }
    expect(file.readAsStringSync(), before);
    expect(settings.forwards('forward-only'), const [
      PortForwardSpec(direction: ForwardDirection.toRemote, port: 8080),
    ]);
    // Saving an unrelated choice must not implicitly opt any old host in.
    settings.setLocalAccess('approved', true);
    final restored = read();
    for (final host in denied) {
      expect(restored.localAccess(host), isFalse, reason: host);
      expect(restored.runsWithoutAsking(host), isFalse, reason: host);
    }
    expect(
      restored.forwards('forward-only'),
      settings.forwards('forward-only'),
    );
    expect(restored.localAccess('approved'), isTrue);
  });

  test(
    'existing explicit grants and approval choices survive save and reload',
    () {
      file.writeAsStringSync(
        jsonEncode({
          'ask': {'localAccess': true},
          'always': {'localAccess': true, 'runsWithoutAsking': true},
          'denied': {'localAccess': false, 'runsWithoutAsking': true},
        }),
      );
      final settings = read();
      expect(settings.localAccess('ask'), isTrue);
      expect(settings.runsWithoutAsking('ask'), isFalse);
      expect(settings.localAccess('always'), isTrue);
      expect(settings.runsWithoutAsking('always'), isTrue);
      expect(settings.runsWithoutAsking('denied'), isFalse);
      settings.keepForward(
        'ask',
        const PortForwardSpec(direction: ForwardDirection.toLocal, port: 3000),
      );
      final saved = jsonDecode(file.readAsStringSync()) as Map;
      expect((saved['ask'] as Map)['localAccess'], isTrue);
      expect((saved['always'] as Map)['localAccess'], isTrue);
      final restored = read();
      expect(restored.localAccess('ask'), isTrue);
      expect(restored.runsWithoutAsking('ask'), isFalse);
      expect(restored.runsWithoutAsking('always'), isTrue);
      expect(restored.localAccess('denied'), isFalse);
      expect(restored.runsWithoutAsking('denied'), isFalse);
    },
  );

  test(
    'revoking access clears always-allow without deleting saved forwards',
    () {
      const forward = PortForwardSpec(
        direction: ForwardDirection.toLocal,
        port: 3000,
      );
      final settings = read();
      settings.setLocalAccess('dev', true);
      settings.setRunsWithoutAsking('dev', true);
      settings.keepForward('dev', forward);
      settings.setLocalAccess('dev', false);
      final restored = read();
      expect(restored.localAccess('dev'), isFalse);
      expect(restored.runsWithoutAsking('dev'), isFalse);
      expect(restored.forwards('dev'), [forward]);
      restored.setLocalAccess('dev', true);
      expect(read().localAccess('dev'), isTrue);
      expect(read().runsWithoutAsking('dev'), isFalse);
      restored.setLocalAccess('dev', false);
      restored.forgetForward('dev', forward);
      expect(jsonDecode(file.readAsStringSync()), isEmpty);
      expect(read().localAccess('dev'), isFalse);
    },
  );
}
