@TestOn('browser')
library;

import 'package:baocode/browser/sidebar_prose_snapshot.dart';
import 'package:baocode/chat/widgets/markdown_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('copy fallback uses visible markers and cells, not Markdown source', () {
    final row = SidebarProseRow.fromWire({
      'role': 'assistant',
      'text': '''
## 结果

**中文** with [link](https://example.com) and `code`.

- first
- second

3. third
4. fourth

| Name | Count |
| --- | --- |
| delta | 2 |

```dart
void main() {}
```
''',
    })!;
    expect(MarkdownView.copyText(row.text), [
      '结果',
      '中文 with link and  code .',
      '• first',
      '• second',
      '3. third',
      '4. fourth',
      'Name\tCount',
      'delta\t2',
      'void main() {}',
    ].join('\n'));
  });
}
