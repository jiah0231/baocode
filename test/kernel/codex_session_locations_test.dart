import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_session_locations.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'versioned location metadata persists in selected BaoCode data directory',
    () async {
      final previous = DataDirectory.current;
      final root = await Directory.systemTemp.createTemp('codex-locations-');
      DataDirectory.current = DataDirectory(root.path);
      try {
        final session = SessionRecord(
          id: 'thread',
          title: 't',
          updatedAt: DateTime(2026),
          cwd: '/old',
          path: '/codex/rollout.jsonl',
        );
        await CodexSessionLocations().move([session], '/new');
        final file = File('${root.path}/state/codex-session-locations.json');
        expect((jsonDecode(await file.readAsString()) as Map)['version'], 1);
        final restored = await CodexSessionLocations().snapshot();
        expect(CodexSessionLocations.apply(restored, session).cwd, '/new');
        expect(
          (await file.parent.list().toList()).where(
            (f) => f.path.endsWith('.tmp'),
          ),
          isEmpty,
        );
        await file.writeAsString('{"version":2,"sessions":{}}');
        await expectLater(
          CodexSessionLocations().snapshot(),
          throwsFormatException,
        );
      } finally {
        DataDirectory.current = previous;
        await root.delete(recursive: true);
      }
    },
  );
}
