import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/composer/composer_files.dart';
import 'package:baocode/workspace/workspace.dart';

import '../workspace_test.dart' show claude, FakeCatalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Workspace> load(PreferenceStore drafts) async {
    final workspace = Workspace(
      kernels: [claude],
      preferences: MemoryPreferenceStore(),
      drafts: drafts,
    );
    await workspace.load();
    return workspace;
  }

  void type(AgentThread thread, String text) => thread.session.draft.save(
    text,
    const TextSelection.collapsed(offset: 1),
    const [],
  );

  test(
    'window drafts are independent, survive reload and preserve main draft',
    () async {
      final drafts = MemoryPreferenceStore({
        'new:/tmp/project': {
          'text': 'main draft',
          'base': 1,
          'extent': 1,
          'images': [],
        },
      });
      var workspace = await load(drafts);
      final selected = workspace.selected;
      final first = workspace.newWindowAgent('/tmp/project');
      final second = workspace.newWindowAgent('/tmp/project');
      expect(first.session.draft.content, isNull);
      expect(second.session.draft.content, isNull);
      final firstState = workspace.windowAgentState(first);
      final secondState = workspace.windowAgentState(second);
      expect(firstState['draftKey'], isNot(secondState['draftKey']));
      type(first, 'first draft');
      type(second, 'second draft');
      workspace.closeWindowAgent(first);
      expect(workspace.threads, contains(first));
      expect(workspace.selected, same(selected));
      workspace.dispose();

      workspace = await load(drafts);
      final restoredSelected = workspace.selected;
      final restoredFirst = workspace.restoreWindowAgent(firstState)!;
      final restoredSecond = workspace.restoreWindowAgent(secondState)!;
      expect(restoredFirst.session.draft.content, 'first draft');
      expect(restoredSecond.session.draft.content, 'second draft');
      expect(workspace.restoreWindowAgent(firstState), same(restoredFirst));
      expect(workspace.selected, same(restoredSelected));
      expect((await drafts.read())['new:/tmp/project'], isNotNull);
      workspace.dispose();
    },
  );

  test(
    'retained hidden windows protect threads without marking them shown',
    () async {
      final workspace = await load(MemoryPreferenceStore());
      final thread = workspace.newWindowAgent('/tmp/project');
      workspace.showAgentWindows([thread, thread], shown: const []);
      workspace.closeWindowAgent(thread);
      expect(workspace.threads, contains(thread));
      expect(workspace.isShown(thread), isFalse);
      workspace.dropDragAgent(thread);
      expect(workspace.threads, contains(thread));
      workspace.showAgentWindows([thread]);
      expect(workspace.isShown(thread), isTrue);
      workspace.showAgentWindows(const []);
      workspace.closeWindowAgent(thread);
      expect(workspace.threads, isNot(contains(thread)));
      workspace.dispose();
    },
  );

  test(
    'saved session resolves to shared thread without selecting it',
    () async {
      final workspace = await load(MemoryPreferenceStore());
      final selected = workspace.selected;
      final thread = workspace.threads.firstWhere(
        (t) => t.id == FakeCatalog.kept.id,
      );
      final state = workspace.windowAgentState(thread);
      expect(workspace.restoreWindowAgent(state), same(thread));
      expect(workspace.selected, same(selected));
      expect(
        workspace.restoreWindowAgent({
          'project': '/tmp/project',
          'sessionId': 'missing',
        }),
        isNull,
      );
      expect(
        workspace.restoreWindowAgent({
          'project': '/tmp/project',
          'draftKey': 'new:/tmp/project',
        }),
        isNull,
      );
      workspace.dispose();
    },
  );
  testWidgets('first session ID migrates only its own draft key', (
    tester,
  ) async {
    final drafts = MemoryPreferenceStore();
    final workspace = (await tester.runAsync(() => load(drafts)))!;
    final first = workspace.newWindowAgent('/tmp/project');
    final second = workspace.newWindowAgent('/tmp/project');
    final firstKey = workspace.windowAgentState(first)['draftKey'];
    final secondKey = workspace.windowAgentState(second)['draftKey'];
    type(first, 'first unsent draft');
    type(second, 'second unsent draft');
    first.session.send(const ComposerMessage(text: 'synthetic test message'));
    for (var i = 0; i < 5 && first.id == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(first.id, isNotNull);
    await tester.pump(const Duration(milliseconds: 600));
    final saved = await drafts.read();
    expect(saved.containsKey(firstKey), isFalse);
    expect((saved[first.id] as Map)['text'], 'first unsent draft');
    expect((saved[secondKey] as Map)['text'], 'second unsent draft');
    expect(
      workspace.restoreWindowAgent(workspace.windowAgentState(first)),
      same(first),
    );
    workspace.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
  test(
    'abandoned drafts restore as sidebar entries and clear/delete stay gone',
    () async {
      final drafts = MemoryPreferenceStore();
      final preferences = MemoryPreferenceStore();
      Workspace make() => Workspace(
        kernels: [claude],
        preferences: preferences,
        drafts: drafts,
      );
      var workspace = make();
      await workspace.load();
      final abandoned = workspace.newWindowAgent('/tmp/project');
      final image = ImageAttachment(
        bytes: Uint8List.fromList([1, 2, 3]),
        mediaType: 'image/png',
        name: 'test.png',
        number: 4,
      );
      abandoned.session.draft.save(
        'unfinished',
        const TextSelection(baseOffset: 1, extentOffset: 3),
        [image],
      );
      workspace.newWindowAgent('/tmp/project');
      final key = workspace.windowAgentState(abandoned)['draftKey'];
      expect(workspace.listsInSidebar(abandoned), isTrue);
      expect((await preferences.read())['windowDrafts'], isNotEmpty);
      workspace.dispose();
      workspace = make();
      await workspace.load();
      final recovered = workspace.threads.singleWhere(
        (t) => workspace.windowAgentState(t)['draftKey'] == key,
      );
      expect(workspace.hasWindowDraft(recovered), isTrue);
      expect(workspace.listsInSidebar(recovered), isTrue);
      expect(recovered.session.draft.content, 'unfinished');
      expect(
        recovered.session.draft.selection,
        const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      expect(recovered.session.draft.images.single.bytes, [1, 2, 3]);
      expect(recovered.session.draft.images.single.name, 'test.png');
      expect(recovered.session.draft.images.single.number, 4);
      type(recovered, '');
      final deleted = workspace.newWindowAgent('/tmp/project');
      type(deleted, 'remove me');
      workspace.delete(deleted);
      workspace.dispose();
      workspace = make();
      await workspace.load();
      expect(workspace.threads.where(workspace.hasWindowDraft), isEmpty);
      expect((await preferences.read())['windowDrafts'], isEmpty);
      workspace.dispose();
    },
  );

  test('changing window folder copies composer without touching another window or main pane', () async {
    final workspace = await load(MemoryPreferenceStore());
    final main = workspace.current;
    final panes = workspace.grid.panes.toList();
    final source = workspace.newWindowAgent('/tmp/project');
    final image = ImageAttachment(
      bytes: Uint8List.fromList([4, 5]),
      mediaType: 'image/png',
    );
    source.session.draft.save(
      'keep this',
      const TextSelection.collapsed(offset: 4),
      [image],
    );
    source.session.draft.insertFiles([
      const ComposerFile('/tmp/project/file.txt'),
    ]);
    source.session.draft.insertCode([
      const CodeReference(path: 'file.dart', start: 1, end: 1, code: 'test'),
    ]);
    source.session.draft.restore(
      'queued test',
      [image],
      sessionMentions: ['synthetic-id'],
    );
    workspace.showAgentWindows([source]);
    final moved = workspace.moveWindowAgent(source, '/tmp/other');
    expect(moved.project.path, '/tmp/other');
    expect(moved.session.draft.pendingCode, source.session.draft.pendingCode);
    expect(moved.session.draft.pendingMessage?.text, 'queued test');
    expect(moved.session.draft.pendingMessage?.sessionMentions, [
      'synthetic-id',
    ]);
    expect(source.session.draft.pendingMessage, isNotNull);
    expect(moved.session.draft.content, 'keep this');
    expect(moved.session.draft.selection, source.session.draft.selection);
    expect(moved.session.draft.images.single.bytes, [4, 5]);
    expect(moved.session.draft.pendingFiles, source.session.draft.pendingFiles);
    expect(
      workspace.windowAgentState(moved)['draftKey'],
      isNot(workspace.windowAgentState(source)['draftKey']),
    );
    workspace.closeWindowAgent(source);
    expect(workspace.threads, contains(source));
    expect(source.session.draft.content, 'keep this');
    expect(source.session.draft.pendingFiles, isNotEmpty);
    expect(workspace.current, same(main));
    expect(workspace.grid.panes, orderedEquals(panes));
    workspace.dispose();
  });
}
