import '../../lib/browser/browser_sidebar_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog lists and searches without opening desktop history', () {
    final catalog = BrowserSidebarChat();
    final browser = Object();
    final owner = Object();
    final entries = List.generate(60, (_) => Object());
    var opens = 0;
    catalog.register(
      owner,
      () => [
        for (var i = 0; i < entries.length; i++)
          BrowserSidebarThread(entries[i], () => 'Conversation ${i + 1}', () {
            opens++;
            return null;
          }),
      ],
    );
    Map<String, Object?> list([int offset = 0, String query = '']) =>
        catalog.handle(browser, {
          'action': 'list',
          'windowId': 1,
          'query': query,
          'offset': offset,
        });
    expect(list()['threads'], hasLength(50));
    expect(list()['more'], isTrue);
    expect(list(50)['threads'], hasLength(10));
    expect(list(50)['more'], isFalse);
    final one = (list(0, 'conversation 60')['threads'] as List).single as Map;
    expect(one['title'], 'Conversation 60');
    expect(opens, 0);
    expect(catalog.handle(browser, {
      'action': 'select',
      'windowId': 1,
      'threadId': one['id'],
    }), {'error': 'missing'});
    expect(opens, 1);
    catalog.unregister(owner);
    expect(list()['threads'], isEmpty);
  });
}
