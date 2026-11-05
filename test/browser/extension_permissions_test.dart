import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled extension preserves its existing permission boundary', () {
    final manifest = jsonDecode(
      File('browser_extension/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    // activeTab makes unpacked extensions eligible for default file:// access.
    // Do not silently add it while importing upstream browser features.
    expect(
      manifest['permissions'],
      unorderedEquals([
        'nativeMessaging',
        'debugger',
        'tabs',
        'tabGroups',
        'alarms',
      ]),
    );
    expect(manifest['host_permissions'] ?? [], isEmpty);
    expect(manifest['optional_permissions'] ?? [], isEmpty);
    expect(manifest['optional_host_permissions'] ?? [], isEmpty);
    expect(manifest['content_scripts'] ?? [], isEmpty);
  });
}
