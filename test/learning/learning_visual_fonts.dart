import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/theme/code_font.dart';

/// The app bundles icon glyphs only. On the Windows visual CI runner load its
/// actual desktop text fonts explicitly: widget tests otherwise paint Ahem.
Future<void> loadLearningVisualFonts() async {
  final icons = FontLoader('codicon')
    ..addFont(rootBundle.load('assets/codicons/codicon.ttf'));
  await icons.load();
  if (!const bool.fromEnvironment('BAOCODE_LEARNING_VISUALS')) return;
  if (!Platform.isWindows) {
    throw StateError('Visual fixtures require the Windows desktop font set');
  }
  final root = '${Platform.environment['WINDIR'] ?? r'C:\Windows'}/Fonts';
  Future<void> load(String family, String file) async {
    final bytes = await File('$root/$file').readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  await load('Roboto', 'segoeui.ttf');
  await load('Segoe UI', 'segoeui.ttf');
  final cjk = ['msyh.ttc', 'msyhl.ttc', 'simsun.ttc'].firstWhere(
    (file) => File('$root/$file').existsSync(),
    orElse: () => throw StateError(
      'Readable Chinese font missing: install Microsoft YaHei on Windows visual runner',
    ),
  );
  await load('Microsoft YaHei UI', cjk);
  await load('Consolas', 'consola.ttf');
  await load('monospace', 'consola.ttf');
  await load('Cascadia Mono', 'consola.ttf');
  // Test fonts do not discover installed families. Select the same available
  // Windows fallback explicitly, rather than letting Ahem claim JetBrains Mono.
  CodeFont.families.value = const ['Consolas', 'Microsoft YaHei UI'];
  if (File('$root/segmdl2.ttf').existsSync()) {
    await load('Segoe MDL2 Assets', 'segmdl2.ttf');
    await load('Segoe Fluent Icons', 'segmdl2.ttf');
  }
}

/// Bound real-I/O fixture failures rather than waiting Flutter's ten minutes.
void learningWidgetTest(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    timeout: const Timeout(Duration(seconds: 60)),
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
