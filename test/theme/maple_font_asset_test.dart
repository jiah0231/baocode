import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled Maple font is the unchanged pinned upstream binary', () {
    final bytes = File('assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf')
        .readAsBytesSync();
    expect(bytes.length, 20563672);
    expect(
      sha256.convert(bytes).toString(),
      '9ae0c348a44a681fa8fa20a34e782e95316cec880102295a128b65760944c0f5',
    );
  });

  test('font ships with its matching OFL and provenance notices', () {
    final license = File('assets/fonts/maple/OFL.txt').readAsStringSync();
    expect(license, contains('Copyright 2022 The Maple Mono Project Authors'));
    expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
    final notice = File('assets/fonts/maple/NOTICE.md').readAsStringSync();
    expect(notice, contains('e4a4c02ebbae8d73ea99b0818708633d004ce4a5'));
    final manifest = File('pubspec.yaml').readAsStringSync();
    expect(manifest, contains('family: Maple Mono Normal NF CN'));
    expect(manifest, contains('assets/fonts/maple/OFL.txt'));
    expect(manifest, contains('assets/fonts/maple/NOTICE.md'));
  });
}
