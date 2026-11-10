import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/window/window_settings.dart';
import 'package:baocode/workspace/main_window.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';

import '../workspace_test.dart' show claude, FakeCatalog;
import 'fake_window_host.dart';

class _DelayedStore extends MemoryPreferenceStore {
  final ready = Completer<void>();
  @override
  Future<Map<String, Object?>> read() async {
    await ready.future;
    return super.read();
  }
}

class _Harness {
  _Harness(
    WidgetTester tester, {
    MemoryPreferenceStore? store,
    MemoryPreferenceStore? drafts,
    PreferenceStore? preferences,
  }) : host = FakeWindowHost(tester.view),
       store = store ?? MemoryPreferenceStore(),
       workspace = Workspace(
         kernels: [claude],
         preferences: preferences ?? MemoryPreferenceStore(),
         drafts: drafts ?? MemoryPreferenceStore(),
       ) {
    windows = AppWindows(
      host: host,
      workspace: workspace,
      store: this.store,
      l10n: () => englishLocalizations,
      settings: () => const WindowSettings(
        ideWindows: IdeWindows.separate,
        restoreWindows: RestoreWindows.all,
      ),
      mainWindow: () => MainWindow.last,
      isDirectory: (_) async => true,
      nextFrame: () async {},
    );
  }
  final FakeWindowHost host;
  final MemoryPreferenceStore store;
  final Workspace workspace;
  late final AppWindows windows;

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(workspace.load);
    await windows.start();
  }

  Future<void> dispose() async {
    await windows.saved;
    windows.dispose();
    workspace.dispose();
  }
}

void main() {
  testWidgets('B and C keep independent chats, selection, focus and IDE', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.start(tester);
    final a = h.workspace.current;
    final panes = h.workspace.grid.panes.toList();
    final b = (await h.windows.newWindow())!;
    final c = (await h.windows.newWindow())!;
    h.host.log.clear();
    h.windows.showChatIn(b);
    final bThread = b.thread!;
    expect(h.host.focused, b.viewId);
    expect(h.host.log, isNot(contains('focus ${h.windows.chat.viewId}')));
    h.windows.showChatIn(c);
    expect(c.thread, isNot(same(bThread)));
    expect(h.workspace.current, same(a));
    expect(h.workspace.grid.panes, orderedEquals(panes));

    h.windows.showIdeIn(b);
    expect(b.chatMode, isFalse);
    expect(b.thread, same(bThread));
    h.windows.showChatIn(b);
    expect(b.chatMode, isTrue);
    expect(b.thread, same(bThread));
    expect(h.host.focused, b.viewId);
    expect(h.workspace.current, same(a));
    expect(h.workspace.grid.panes, orderedEquals(panes));
    h.windows.showIdeIn(b);
    h.windows.showInWindow(b, bThread);
    expect(b.chatMode, isTrue);
    expect(b.thread, same(bThread));
    expect(h.host.focused, b.viewId);
    expect(h.workspace.current, same(a));
    expect(h.workspace.grid.panes, orderedEquals(panes));
    await h.dispose();
  });

  testWidgets('local selection and closing shared chat preserve other window', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.start(tester);
    final a = h.workspace.current;
    final panes = h.workspace.grid.panes.toList();
    final b = (await h.windows.newWindow())!;
    final c = (await h.windows.newWindow())!;
    h.windows.showChatIn(b);
    h.windows.showChatIn(c);
    final shared = b.thread!;
    h.windows.showInWindow(c, shared);
    expect(c.thread, same(shared));
    expect(h.workspace.current, same(a));
    expect(h.workspace.grid.panes, orderedEquals(panes));
    h.windows.showIdeIn(c); // Retained but not visibly reading this chat.
    expect(await h.windows.requestClose(b), isTrue);
    expect(h.workspace.threads, contains(shared));
    expect(c.thread, same(shared));
    expect(h.workspace.isShown(shared), isFalse);
    h.windows.showChatIn(c);
    expect(c.thread, same(shared));
    expect(h.host.focused, c.viewId);
    await h.dispose();
  });

  testWidgets('windows state restores each mode and independent draft', (
    tester,
  ) async {
    final store = MemoryPreferenceStore();
    final drafts = MemoryPreferenceStore();
    final first = _Harness(tester, store: store, drafts: drafts);
    await first.start(tester);
    final b = (await first.windows.showFolder('/w/b'))!;
    final c = (await first.windows.showFolder('/w/c'))!;
    first.windows.showChatIn(b);
    first.windows.showChatIn(c);
    b.thread!.session.draft.save(
      'draft B',
      const TextSelection.collapsed(offset: 2),
      const [],
    );
    c.thread!.session.draft.save(
      'draft C',
      const TextSelection.collapsed(offset: 3),
      const [],
    );
    first.windows.showIdeIn(c);
    first.windows.focus(b);
    await first.windows.saved;
    final data = await store.read();
    final kept = (data['windows'] as List).cast<Map>();
    expect(kept.first['folder'], '/w/b');
    expect(kept.first['chatMode'], isTrue);
    expect(kept.first['conversation'], isA<Map>());
    await first.dispose();

    final next = _Harness(tester, store: store, drafts: drafts);
    await next.start(tester);
    final current = next.workspace.current;
    await next.windows.prepareLaunch();
    await next.windows.restore();
    final rb = next.windows.ideWindows.firstWhere((w) => w.folder == '/w/b');
    final rc = next.windows.ideWindows.firstWhere((w) => w.folder == '/w/c');
    expect(rb.chatMode, isTrue);
    expect(rc.chatMode, isFalse);
    expect(rb.thread!.session.draft.content, 'draft B');
    expect(rc.thread!.session.draft.content, 'draft C');
    expect(rb.thread, isNot(same(rc.thread)));
    expect(next.host.focused, rb.viewId);
    expect(next.workspace.current, same(current));
    next.windows.showChatIn(rc);
    expect(rc.thread!.session.draft.content, 'draft C');
    await next.dispose();
  });

  testWidgets('session restoration waits for a loading workspace', (
    tester,
  ) async {
    final gate = _DelayedStore();
    final h = _Harness(
      tester,
      preferences: gate,
      store: MemoryPreferenceStore({
        'version': 1,
        'leftIn': 'ide',
        'windows': [
          {
            'folder': '/tmp/project',
            'chatMode': true,
            'conversation': {
              'project': '/tmp/project',
              'sessionId': FakeCatalog.kept.id,
            },
          },
        ],
      }),
    );
    await h.windows.start();
    await h.windows.prepareLaunch();
    final loading = h.workspace.load();
    var restored = false;
    final restoring = h.windows.restore().then((_) => restored = true);
    await tester.pump();
    expect(restored, isFalse);
    gate.ready.complete();
    await tester.runAsync(() async {
      await loading;
      await restoring;
    });
    expect(h.windows.ideWindows.single.thread!.id, FakeCatalog.kept.id);
    expect(h.windows.ideWindows.single.chatMode, isTrue);
    await h.dispose();
  });

  testWidgets(
    'legacy windows state still opens an IDE without a chat selection',
    (tester) async {
      final h = _Harness(
        tester,
        store: MemoryPreferenceStore({
          'version': 1,
          'leftIn': 'ide',
          'windows': [
            {'folder': '/w/b'},
            {'chat': true},
          ],
        }),
      );
      await h.start(tester);
      await h.windows.prepareLaunch();
      await h.windows.restore();
      final b = h.windows.ideWindows.single;
      expect(b.folder, '/w/b');
      expect(b.chatMode, isFalse);
      expect(b.thread, isNull);
      h.windows.showChatIn(b);
      expect(b.thread!.project.path, '/w/b');
      expect(b.chatMode, isTrue);
      await h.dispose();
    },
  );

  testWidgets(
    'missing or deleted session leaves IDE alive with a local new chat',
    (tester) async {
      final h = _Harness(
        tester,
        store: MemoryPreferenceStore({
          'version': 1,
          'leftIn': 'ide',
          'windows': [
            {
              'folder': '/w/b',
              'chatMode': true,
              'conversation': {
                'project': '/w/b',
                'sessionId': 'deleted-session',
              },
            },
          ],
        }),
      );
      await h.start(tester);
      final main = h.workspace.current;
      await h.windows.prepareLaunch();
      await h.windows.restore();
      final b = h.windows.ideWindows.single;
      final thread = b.thread!;
      final view = b.viewId;
      expect(thread.id, isNull);
      expect(thread.project.path, '/w/b');
      expect(b.chatMode, isTrue);
      h.workspace.delete(thread);
      expect(h.windows.ideWindows, contains(b));
      expect(b.viewId, view);
      expect(b.folder, '/w/b');
      expect(b.thread, isNot(same(thread)));
      expect(b.thread!.id, isNull);
      expect(b.chatMode, isTrue);
      expect(h.workspace.current, same(main));
      expect(h.host.log, isNot(contains('close $view')));
      await h.dispose();
    },
  );
}
