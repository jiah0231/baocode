// Exercise the original assistant prose widget, not a parallel renderer.
// Synthetic data only; this entry point does not connect to a real session.
import 'package:baocode/chat/widgets/assistant_text.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/render_theme_web.dart' as browser_theme;
import 'package:flutter/material.dart';

void main() {
  // Synthetic Windows host appearance, independent of the CI runner's OS.
  browser_theme.installBrowserRenderTheme(windowsFonts: true);
  runApp(MaterialApp(
    theme: buildAppTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const _Fixture(),
  ));
}

class _Fixture extends StatefulWidget {
  const _Fixture();

  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  static const _prefix = '''
**中文强调** 与 `inline code`。

| 项目 | 状态 |
| --- | --- |
| 流式输出 | 正常 |

```3:3:lib/chat/example.dart
final value = 42;
```

```mermaid
flowchart TD
  A[开始] --> B[整理资料]
  B --> C[核对内容]
  C --> D[完成]
''';
  bool _complete = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          onPressed: () => setState(() => _complete = true),
          icon: const Icon(Icons.play_arrow),
        ),
      ],
    ),
    body: Center(
      child: SizedBox(
        width: 380,
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              AssistantText(_prefix + (_complete ? '```\n\n最后一段已追加。' : '')),
            ],
          ),
        ),
      ),
    ),
  );
}
