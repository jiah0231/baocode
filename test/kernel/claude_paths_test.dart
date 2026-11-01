import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (path, directory, name) in [
    (r'C:\project\color.txt', r'C:\project', 'color.txt'),
    (r'\\server\share\color.txt', r'\\server\share', 'color.txt'),
    ('C:/project/color.txt', 'C:/project', 'color.txt'),
    ('/remote/project/color.txt', '/remote/project', 'color.txt'),
    (r'/remote/project/color\name.txt', '/remote/project', r'color\name.txt'),
    ('color.txt', '', 'color.txt'),
  ]) {
    test('tool/diff labels split host-native path $path', () {
      final events = <KernelEvent>[];
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: events.add,
        nextSeq: () => ++seq,
      );
      void call(String id, String tool) => translator.translate({
        'type': 'assistant',
        'message': {
          'id': 'message-$id',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': id,
              'name': tool,
              'input': {'file_path': path, 'content': 'blue\n'},
            },
          ],
        },
      });
      call('read', 'Read');
      final read = events
          .whereType<ItemUpserted>()
          .map((event) => event.item)
          .whereType<ToolCallItem>()
          .last;
      expect(read.target, name);
      expect(read.path, path);
      call('write', 'Write');
      translator.translate({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'write', 'content': 'ok'},
          ],
        },
        'tool_use_result': {
          'type': 'create',
          'filePath': path,
          'content': 'blue\n',
        },
      });
      final diff = events
          .whereType<ItemUpserted>()
          .map((event) => event.item)
          .whereType<CodeDiffItem>()
          .single;
      expect(diff.fileName, name);
      expect(diff.directory, directory);
      expect(diff.lines, hasLength(2));
      // Display normalization must not change paths used for undo/review.
      final change = events.whereType<FileEdited>().single.change;
      expect(change.path, path);
      expect(change.fileName, name);
      expect(change.directory, directory);
    });
  }
}
