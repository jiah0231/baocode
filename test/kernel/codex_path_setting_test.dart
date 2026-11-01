import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:baocode/kernel/codex/codex_path_setting.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/kernel/codex/codex_process_transport_io.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('baocode-codex-path-');
  });
  tearDown(() {
    CodexPathSetting.current = () => null;
    ClaudeEnvironment.use(null);
    root.deleteSync(recursive: true);
  });

  test(
    'empty and invalid settings use discovery; configured paths are trimmed',
    () {
      expect(CodexPathSetting.parse(null), isNull);
      expect(CodexPathSetting.parse(false), isNull);
      expect(CodexPathSetting.parse('  '), isNull);
      expect(CodexPathSetting.parse(' /opt/codex '), '/opt/codex');
    },
  );

  test(
    'explicit executable wins over PATH, including a path with spaces',
    () async {
      final named = File(p.join(root.path, 'my codex.exe'))
        ..writeAsStringSync('');
      final other = File(p.join(root.path, 'codex'))..writeAsStringSync('');
      expect(
        await CodexProcessTransport.locateExecutable({
          'PATH': other.parent.path,
        }, configuredPath: named.path),
        named.path,
      );
    },
  );

  test('home-relative paths expand on the local host', () async {
    final named = File(p.join(root.path, 'codex'))..writeAsStringSync('');
    expect(
      await CodexProcessTransport.locateExecutable({
        'HOME': root.path,
        'USERPROFILE': root.path,
      }, configuredPath: '~/codex'),
      named.path,
    );
  });

  test(
    'missing, relative and directory overrides fail rather than fall back',
    () async {
      for (final path in [p.join(root.path, 'gone'), 'codex', root.path]) {
        await expectLater(
          CodexProcessTransport.locateExecutable({
            'PATH': root.path,
          }, configuredPath: path),
          throwsA(
            isA<CodexUnavailable>().having(
              (e) => e.detail,
              'actionable error',
              contains('Settings → General → Codex'),
            ),
          ),
        );
      }
    },
  );

  test(
    'local status reports a bad configured path without running another CLI',
    () async {
      CodexPathSetting.current = () => p.join(root.path, 'missing');
      ClaudeEnvironment.use({'HOME': root.path, 'PATH': '/usr/bin:/bin'});
      expect(await localCodexStatus(), isA<LocalCodexFailed>());
    },
  );

  test('local launch and version check use the selected executable', () async {
    final args = File(p.join(root.path, 'args'));
    final named = File(p.join(root.path, 'my codex'))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$1" = "--version" ]; then echo "codex-cli 1.2.3"; exit 0; fi\n'
        'printf "%s\\n" "\$@" > "${args.path}"\n',
      );
    Process.runSync('chmod', ['+x', named.path]);
    CodexPathSetting.current = () => named.path;
    ClaudeEnvironment.use({'HOME': root.path, 'PATH': '/usr/bin:/bin'});
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    NetworkProxy.instance.follow(
      changes,
      (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
    );
    CodexProcessTransport.registry = CodexProcessRegistry(
      file: File(p.join(root.path, 'processes.json')),
      lookup: (_) async => null,
      signal: (_) => false,
    );
    expect(
      await localCodexStatus(),
      isA<LocalCodexFound>()
          .having((s) => s.path, 'path', named.path)
          .having((s) => s.version, 'version', 'codex-cli 1.2.3'),
    );
    final transport = await startCodexProcess(CodexLaunch(cwd: root.path));
    await transport.exited.timeout(const Duration(seconds: 10));
    await CodexProcessTransport.registry.flush();
    expect(args.readAsLinesSync(), ['app-server']);
  }, skip: Platform.isWindows ? 'Uses a POSIX fixture executable.' : false);

  test(
    'Windows npm shim runs from a path containing spaces and ampersands',
    () async {
      final bin = Directory(p.join(root.path, 'my codex & tools'))
        ..createSync();
      final args = File(p.join(bin.path, 'args.txt'));
      final named = File(p.join(bin.path, 'codex.cmd'))
        ..writeAsStringSync(
          '@echo off\r\n'
          'if "%~1"=="--version" (\r\n'
          '  echo codex-cli 1.2.3\r\n'
          '  exit /b 0\r\n'
          ')\r\n'
          'echo %~1>"%~dp0args.txt"\r\n'
          'exit /b 0\r\n',
        );
      CodexPathSetting.current = () => named.path;
      ClaudeEnvironment.use({
        ...Platform.environment,
        'HOME': root.path,
        'USERPROFILE': root.path,
      });
      final changes = ValueNotifier(0);
      addTearDown(changes.dispose);
      NetworkProxy.instance.follow(
        changes,
        (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
      );
      CodexProcessTransport.registry = CodexProcessRegistry(
        file: File(p.join(root.path, 'processes.json')),
        lookup: (_) async => null,
        signal: (_) => false,
      );
      expect(
        await CodexProcessTransport.locateExecutable(
          Platform.environment,
          configuredPath: named.path,
        ),
        named.path,
      );
      expect(
        await localCodexStatus(),
        isA<LocalCodexFound>()
            .having((s) => s.path, 'path', named.path)
            .having((s) => s.version, 'version', 'codex-cli 1.2.3'),
      );
      final transport = await startCodexProcess(CodexLaunch(cwd: root.path));
      await transport.exited.timeout(const Duration(seconds: 10));
      await CodexProcessTransport.registry.flush();
      expect(args.readAsStringSync().trim(), 'app-server');
    },
    skip: !Platform.isWindows ? 'Exercises the Windows npm shim.' : false,
  );
}
