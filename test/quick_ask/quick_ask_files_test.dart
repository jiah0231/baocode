import 'dart:convert';
import 'dart:io';

import 'package:baocode/quick_ask/quick_ask_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('quick-ask-'));
  tearDown(() => directory.deleteSync(recursive: true));

  File file(String name) => File('${directory.path}/$name');
  Matcher fails(QuickAskFileFailure reason) => throwsA(
    isA<QuickAskFileException>().having((e) => e.reason, 'reason', reason),
  );

  test(
    'reads an explicit UTF-8 disk snapshot with only its basename',
    () async {
      final source = file('unicode.dart')
        ..writeAsStringSync('中文😀\r\nreturn 1;\n');
      final snapshot = await QuickAskFileContext.read(source.path);
      source.writeAsStringSync('changed after capture');
      expect(snapshot.name, 'unicode.dart');
      expect(snapshot.text, '中文😀\r\nreturn 1;\n');
      expect(snapshot.toJson(), {
        'name': 'unicode.dart',
        'text': snapshot.text,
      });
      expect(jsonEncode(snapshot.toJson()), isNot(contains(directory.path)));
    },
  );

  test(
    'supports the exact character limit without partial truncation',
    () async {
      final source = file('limit.txt')..writeAsStringSync('中' * 8000);
      expect((await QuickAskFileContext.read(source.path)).text.length, 8000);
      source.writeAsStringSync('中' * 8001);
      await expectLater(
        QuickAskFileContext.read(source.path),
        fails(QuickAskFileFailure.tooLarge),
      );
      source.writeAsBytesSync(
        List.filled(QuickAskFileContext.maxBytes + 1, 65),
      );
      await expectLater(
        QuickAskFileContext.read(source.path),
        fails(QuickAskFileFailure.tooLarge),
      );
    },
  );

  test(
    'rejects binaries, invalid UTF-8, directories and missing files',
    () async {
      final source = file('binary.txt');
      for (final bytes in [
        [65, 0, 66],
        [65, 0xff, 66],
        [65, 27, 66],
      ]) {
        source.writeAsBytesSync(bytes);
        await expectLater(
          QuickAskFileContext.read(source.path),
          fails(QuickAskFileFailure.notText),
        );
      }
      await expectLater(
        QuickAskFileContext.read(directory.path),
        fails(QuickAskFileFailure.unreadable),
      );
      await expectLater(
        QuickAskFileContext.read(file('missing').path),
        fails(QuickAskFileFailure.unreadable),
      );
    },
  );
}
