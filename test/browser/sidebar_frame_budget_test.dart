import 'dart:convert';

import 'package:baocode/browser/sidebar_frame_budget.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> decoded(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

void main() {
  test('counts fully escaped UTF-8 while preserving CJK and emoji', () {
    final result = {
      'text': List.filled(35000, '中文🙂"\\\n\u0001').join(),
    };
    final body = encodeSidebarResult('界🙂"\u0001', result);
    expect(body.length, lessThanOrEqualTo(sidebarResultMaxBytes));
    expect(decoded(body)['result'], result);
    expect(decoded(body)['requestId'], '界🙂"\u0001');
  });

  test('accepts the exact boundary including the envelope', () {
    final overhead = encodeSidebarResult('request', {'text': ''}).length;
    final text = List.filled(sidebarResultMaxBytes - overhead, 'a').join();
    final exact = encodeSidebarResult('request', {'text': text});
    expect(exact.length, sidebarResultMaxBytes);
    expect(decoded(exact)['result'], {'text': text});
    expect(
      decoded(encodeSidebarResult('request', {'text': '${text}a'}))['result'],
      {'error': 'frame_too_large'},
    );
  });

  test('an oversized inline image returns an error, not partial bytes', () {
    final image = base64Encode(List<int>.filled(800 * 1024, 0));
    final body = encodeSidebarResult('attachment', {
      'items': [{'images': [image]}],
    });
    expect(body.length, lessThan(256));
    expect(decoded(body), {
      'type': 'sidebarChatResult',
      'requestId': 'attachment',
      'result': {'error': 'frame_too_large'},
    });
  });
}
