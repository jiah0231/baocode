import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/workspace/chat_grid.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workspace_test.dart' show claude, FakeCatalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'main pane tabs and independent window drafts restore together',
    () async {
      addTearDown(FakeCatalog.started.clear);
      FakeCatalog.started.addAll([
        for (final id in ['tab-a', 'tab-b'])
          SessionRecord(
            id: id,
            title: id,
            updatedAt: DateTime(2026, 9, 28),
            cwd: '/tmp/project',
          ),
      ]);
      final preferences = MemoryPreferenceStore();
      final drafts = MemoryPreferenceStore();
      Workspace make() => Workspace(
        kernels: [claude],
        preferences: preferences,
        drafts: drafts,
      );
      var workspace = make();
      await workspace.load();
      AgentThread byId(String id) =>
          workspace.threads.firstWhere((thread) => thread.id == id);
      final mainDraft = workspace.selected;
      mainDraft.session.draft.save(
        'main draft',
        const TextSelection.collapsed(offset: 4),
        const [],
      );
      final kept = byId(FakeCatalog.kept.id);
      workspace
        ..openBeside(kept, mainDraft, PaneSide.right)
        ..openInPlaceOf(kept, byId('tab-a'))
        ..openInPlaceOf(byId('tab-a'), byId('tab-b'))
        ..raiseCovered(byId('tab-b'), byId('tab-a'));
      final states = <Map<String, Object?>>[];
      for (final text in ['window B', 'window C']) {
        final thread = workspace.newWindowAgent('/tmp/project');
        thread.session.draft.save(
          text,
          const TextSelection.collapsed(offset: 2),
          const [],
        );
        states.add(workspace.windowAgentState(thread));
      }
      workspace.dispose();

      workspace = make();
      await workspace.load();
      expect(workspace.grid.panes, hasLength(2));
      expect(workspace.selected.id, 'tab-a');
      expect(workspace.grid.at(0)!.session.draft.content, 'main draft');
      final pane = workspace.grid.at(1)!;
      expect(workspace.grid.tabs(pane).map((tab) => tab.id), [
        FakeCatalog.kept.id,
        'tab-a',
        'tab-b',
      ]);
      for (var index = 0; index < states.length; index++) {
        final thread = workspace.restoreWindowAgent(states[index])!;
        expect(thread.session.draft.content, ['window B', 'window C'][index]);
        expect(workspace.grid.contains(thread), isFalse);
        expect(workspace.grid.tabs(pane), isNot(contains(thread)));
        expect(workspace.listsInSidebar(thread), isTrue);
      }
      expect(workspace.selected, same(pane));
      expect(workspace.grid.uncover(pane)?.id, 'tab-b');
      workspace.dispose();
    },
  );

  test(
    'window restoration never takes another kernel session with the same ID',
    () async {
      final other = KernelDescriptor(
        id: 'other-kernel',
        label: 'Other',
        icon: claude.icon,
        description: '',
        catalog: FakeCatalog(),
        create: claude.create,
      );
      final workspace = Workspace(
        kernels: [claude, other],
        preferences: MemoryPreferenceStore(),
      );
      await workspace.load();
      final state = {
        'project': '/tmp/project',
        'sessionId': FakeCatalog.kept.id,
      };
      final main = workspace.current;
      // The catalog deduplicates session IDs across backends. If only the
      // other backend's record was loaded, refuse it instead of mixing chats.
      expect(
        workspace.restoreWindowAgent({...state, 'kernel': other.id}),
        isNull,
      );
      expect(
        workspace.restoreWindowAgent({...state, 'kernel': claude.id})?.kernel,
        same(claude),
      );
      expect(workspace.restoreWindowAgent(state), isNotNull);
      expect(
        workspace.restoreWindowAgent({...state, 'kernel': 'removed'}),
        isNull,
      );
      expect(workspace.current, same(main));
      workspace.dispose();
    },
  );
}
