import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/widgets/markdown_view.dart';
import 'package:baocode/icons/agent_brand_mark.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/main.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/workspace/workspace.dart';

// Opt-in, local review images, not platform-dependent checked-in goldens:
// flutter test test/theme/pebrel_visual_test.dart \
//   --dart-define=PEBREL_PREVIEWS=true
// Uses the actual application, sidebar, transcript and composer. All sessions
// and conversation content are synthetic; no process or network is started.
const _previews = bool.fromEnvironment('PEBREL_PREVIEWS');
const _project = '/preview/sample-project';
const _answer = '''
## Readable conversations · 清晰的对话

English body text stays calm and readable. 中文正文保持自然的阅读节奏。

**Important decisions stand out.** **关键结论清楚可见。** Muted details should not compete with the answer.

- Review the [Flutter documentation](https://flutter.dev) before editing.
- Keep `themeColors` and `文字层级` distinct from surrounding prose.

### Implementation · 实现细节

```dart
final title = 'Hello, 世界';
final ready = true;
print(title); // A small, readable example
```

```diff
- final spacing = 8;
+ final spacing = 12;
```

> A quieter surface gives the content room to breathe. 留白让内容更容易阅读。
''';

class _PreviewCatalog implements SessionCatalog {
  _PreviewCatalog(this.id, this.title);
  final String id;
  final String title;

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: _project, sessions: await sessionsIn(_project)),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [
    SessionRecord(
      id: id,
      title: title,
      cwd: _project,
      updatedAt: DateTime.utc(2025, 1, 1),
    ),
  ];

  @override
  Future<void> delete(String id) async =>
      throw UnsupportedError('Read-only preview');
}

class _PreviewKernel with KernelEventSource implements AgentKernel {
  _PreviewKernel(this.descriptor);
  @override
  final KernelDescriptor descriptor;
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  String? get sessionId => null;
  @override
  Future<void> get stopped async {}

  void populate() {
    emit(
      ItemUpserted(
        nextSeq,
        'question',
        const UserMessageItem(
          text: 'Please review the typography. 请检查文字层级和界面细节。',
        ),
      ),
    );
    emit(ItemUpserted(nextSeq, 'answer', const AssistantTextItem(_answer)));
  }

  @override
  void prepare() {}
  @override
  void release() {}
  @override
  void restart() {}
  @override
  void cancel() {}
  @override
  void answer(String requestId, InteractionAnswer answer) =>
      throw UnsupportedError('Read-only preview');
  @override
  void send(KernelTurn turn) => throw UnsupportedError('Read-only preview');
  @override
  void dispose() => closeEvents();
}

Future<void> _loadPreviewFonts() async {
  // Flutter adds this real icon asset when uses-material-design is true.
  // Load its own family so ordinary controls do not render as Ahem boxes.
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  // Use the shipped CJK font rather than a host-dependent substitution or
  // Flutter tests' Ahem boxes. This exercises the real bundled-font setting.
  for (final (family, path) in [
    (
      'Maple Mono Normal NF CN',
      'assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf',
    ),
    (Codicons.fontFamily, 'assets/codicons/codicon.ttf'),
  ]) {
    await (FontLoader(family)..addFont(
          Future.value(ByteData.sublistView(await File(path).readAsBytes())),
        ))
        .load();
  }
}

/// Only capture Maple-off when exact, individually addressable Windows font
/// files are available. Do not alias Segoe UI as Roboto, substitute Maple, or
/// guess which face FontLoader selects from a Microsoft YaHei TTC collection.
/// Standard CI images may only have msyh.ttc; then this remains a layout test.
Future<bool> _loadWindowsPreviewFonts() async {
  if (!Platform.isWindows) return false;
  final windows = Platform.environment['WINDIR'];
  if (windows == null) return false;
  final fonts = <(String, String)>[
    for (final file in [
      'segoeui.ttf',
      'segoeuib.ttf',
      'segoeuii.ttf',
      'segoeuiz.ttf',
    ])
      ('Segoe UI', file),
    for (final file in [
      'consola.ttf',
      'consolab.ttf',
      'consolai.ttf',
      'consolaz.ttf',
    ])
      ('Consolas', file),
    ('Microsoft YaHei UI', 'msyhui.ttf'),
  ];
  if (fonts.any((font) => !File('$windows/Fonts/${font.$2}').existsSync())) {
    return false;
  }
  for (final family in fonts.map((font) => font.$1).toSet()) {
    final loader = FontLoader(family);
    for (final font in fonts.where((font) => font.$1 == family)) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            await File('$windows/Fonts/${font.$2}').readAsBytes(),
          ),
        ),
      );
    }
    await loader.load();
  }
  return true;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_previews) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.binding.rootElement!);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/pebrel-previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  for (final (theme, width, scale, maple) in [
    for (final theme in [
      'Silver Light',
      'Catppuccin Macchiato',
      'Catppuccin Latte',
    ])
      for (final (width, scale) in [(1400.0, 100), (1100.0, 125)])
        (theme, width, scale, true),
    ('Silver Light', 1100.0, 125, false),
  ]) {
    testWidgets(
      '$theme real chat at ${width.toInt()}px / $scale% / Maple $maple',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final previousThemes = WorkbenchThemeService.instance;
        final previousScale = CodeFont.uiScale.value;
        final previousMaple = CodeFont.mapleFont.value;
        final themes = WorkbenchThemeService();
        WorkbenchThemeService.instance = themes;
        addTearDown(() {
          WorkbenchThemeService.instance = previousThemes;
          CodeFont.uiScale.value = previousScale;
          CodeFont.mapleFont.value = previousMaple;
        });
        var captureReady = maple;
        await tester.runAsync(() async {
          await themes.initialize();
          await themes.setColorTheme('Pebrel $theme');
          if (_previews) {
            await _loadPreviewFonts();
            if (!maple) {
              captureReady = await _loadWindowsPreviewFonts();
              if (!captureReady) {
                debugPrint(
                  'Maple-off: layout assertions only. Exact Windows '
                  'font files unavailable; no aesthetic preview emitted. '
                  'Ahem fallback is not representative of the desktop app.',
                );
              }
            }
            // Finish SVG compilation before the first frame is captured.
            for (final asset in [
              'assets/model_icons/claude.svg',
              'assets/model_icons/claudecode.svg',
              'assets/model_icons/codex.svg',
              'assets/model_icons/openai.svg',
              'assets/branding/logo.svg',
            ]) {
              await SvgAssetLoader(asset).loadBytes(null);
            }
          }
        });
        expect(themes.colorThemeId, 'Pebrel $theme');
        CodeFont.uiScale.value = scale;
        CodeFont.mapleFont.value = maple;

        final created = <_PreviewKernel>[];
        KernelDescriptor descriptor(String id, String label, String logo) {
          late final KernelDescriptor result;
          result = KernelDescriptor(
            id: id,
            label: label,
            logo: logo,
            icon: Icons.terminal,
            description: 'Offline visual test fixture',
            catalog: _PreviewCatalog(id, '$label · Typography review'),
            create: (_) {
              final kernel = _PreviewKernel(result);
              created.add(kernel);
              return kernel;
            },
          );
          return result;
        }

        final workspace = Workspace(
          kernels: [
            descriptor('claude-code', 'Claude Code', 'claudecode'),
            descriptor('codex', 'Codex', 'codex'),
          ],
        );
        workspace.sidebarGrouping = 'project';
        await tester.pumpWidget(BaoCodeApp(workspace: workspace));
        await tester.runAsync(workspace.load);
        await tester.pump();
        final selected = workspace.threads.firstWhere(
          (thread) => thread.record?.id == 'claude-code',
        );
        workspace.select(selected);
        await tester.pump();
        for (final kernel in created) {
          kernel.populate();
        }
        await tester.pumpAndSettle();

        expect(find.byType(Sidebar), findsOneWidget);
        expect(find.byType(ChatComposer), findsOneWidget);
        expect(find.byType(MarkdownView), findsWidgets);
        final marks = tester
            .widgetList<AgentBrandMark>(
              find.descendant(
                of: find.byType(Sidebar),
                matching: find.byType(AgentBrandMark),
              ),
            )
            .map((mark) => mark.logo);
        expect(marks, containsAll(['claudecode', 'codex']));
        expect(workspace.selected, same(selected));
        expect(tester.takeException(), isNull);
        final name =
            '${theme.toLowerCase().replaceAll(' ', '-')}'
            '-${width.toInt()}-$scale${maple ? '' : '-maple-off-windows'}';
        if (captureReady) await _capture(tester, '$name-bottom');
        // A scaled transcript may be taller than the viewport. Capture its
        // beginning too so headings and body cannot silently escape review.
        final historyScroll = tester
            .stateList<ScrollableState>(
              find.descendant(
                of: find.byType(ChatHistoryView),
                matching: find.byType(Scrollable),
              ),
            )
            .where(
              (state) =>
                  state.position.axis == Axis.vertical &&
                  state.position.viewportDimension > 200,
            )
            .firstOrNull;
        if (historyScroll != null) {
          historyScroll.position.jumpTo(
            historyScroll.position.axisDirection == AxisDirection.up
                ? historyScroll.position.maxScrollExtent
                : historyScroll.position.minScrollExtent,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (captureReady) await _capture(tester, '$name-top');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      variant: maple
          ? const DefaultTestVariant()
          : TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
