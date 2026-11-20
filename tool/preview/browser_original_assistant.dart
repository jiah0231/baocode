// Exercise the original assistant prose widget, not a parallel renderer.
// Synthetic data only; this entry point does not connect to a real session.
import 'package:baocode/chat/widgets/assistant_text.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: _Fixture(),
));

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
              AssistantText(_prefix + (_complete ? '最后一段已追加。' : '')),
            ],
          ),
        ),
      ),
    ),
  );
}
