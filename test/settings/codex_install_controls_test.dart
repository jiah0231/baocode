import 'dart:async';

import 'package:baocode/kernel/codex/codex_install.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/settings/pages/codex_install_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Installer implements CodexInstaller {
  static int _ids = 0;
  @override
  final String directory = 'fake-install-${_ids++}';
  @override
  bool get supported => true;
  int calls = 0;
  Completer<String>? completion;
  Object? failure;
  @override
  Future<CodexInstallRelease> latest() async => CodexInstallRelease(
    version: '1.2.3',
    target: 'test',
    url: Uri.https('github.com', '/openai/codex/releases/test'),
    sha256: 'fixture',
    size: 1000,
  );
  @override
  Future<String> install(
    CodexInstallRelease release,
    void Function(String) progress,
  ) async {
    calls++;
    progress('Downloading fixture');
    if (failure != null) throw failure!;
    return completion == null ? '/managed/codex.exe' : completion!.future;
  }
}

Future<void> show(
  WidgetTester tester,
  _Installer installer,
  Future<void> Function(String) selected,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CodexInstallControls(installer: installer, onInstalled: selected),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('installation requires confirmation and Cancel does nothing', (
    tester,
  ) async {
    final installer = _Installer();
    final selected = <String>[];
    await show(tester, installer, (path) async => selected.add(path));
    expect(installer.calls, 0);
    await tester.tap(find.text('Install / update…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1.2.3 ·'), findsOneWidget);
    expect(installer.calls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(installer.calls, 0);
    expect(selected, isEmpty);
    await tester.tap(find.text('Install / update…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install and use'));
    await tester.pumpAndSettle();
    expect(installer.calls, 1);
    expect(selected, ['/managed/codex.exe']);
    expect(find.textContaining('Installed and selected'), findsOneWidget);
  });

  testWidgets('failure is visible without changing the selected executable', (
    tester,
  ) async {
    final installer = _Installer()..failure = StateError('Checksum failed');
    var selected = false;
    await show(tester, installer, (_) async {
      selected = true;
    });
    await tester.tap(find.text('Install / update…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install and use'));
    await tester.pumpAndSettle();
    expect(selected, isFalse);
    expect(find.textContaining('Checksum failed'), findsOneWidget);
  });

  testWidgets(
    'closing and reopening Settings retains running progress and result',
    (tester) async {
      final completion = Completer<String>();
      final installer = _Installer()..completion = completion;
      final selected = <String>[];
      Future<void> select(String path) async => selected.add(path);
      await show(tester, installer, select);
      await tester.tap(find.text('Install / update…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install and use'));
      await tester.pumpAndSettle();
      expect(find.text('Working…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await show(tester, installer, select);
      expect(find.text('Working…'), findsOneWidget);
      expect(find.text('Downloading fixture'), findsOneWidget);
      completion.complete('/managed/codex.exe');
      await tester.pumpAndSettle();
      expect(installer.calls, 1);
      expect(selected, ['/managed/codex.exe']);
      expect(find.textContaining('Installed and selected'), findsOneWidget);
    },
  );
}
