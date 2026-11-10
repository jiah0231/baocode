import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/ide/ide_chat_title.dart';
import 'package:baocode/ide/ide_welcome.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/main.dart';
import 'package:baocode/search/search_palette.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/window/window_settings.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:baocode/workspace/back_to_chat_button.dart';
import 'package:baocode/workspace/new_chat_folder_bar.dart';
import 'package:baocode/workspace/open_in_editor_button.dart';

import 'fake_window_host.dart';

/// The app with windows of its own, each a view of the test's engine: the
/// chat's (the test's view) and those the IDE opens.
Future<(AppWindows, FakeWindowHost, Workspace)> _pumpApp(
  WidgetTester tester, {
  WindowSettings Function()? settings,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final messenger = tester.binding.defaultBinaryMessenger;
  for (final name in [
    'baocode/window',
    for (var id = 1; id < 6; id++) 'baocode/window.$id',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
    );
  }
  final host = FakeWindowHost(tester.view);
  final workspace = Workspace.mock();
  final windows = AppWindows(
    host: host,
    workspace: workspace,
    l10n: () => englishLocalizations,
    settings:
        settings ?? () => const WindowSettings(ideWindows: IdeWindows.separate),
    isDirectory: (path) async => true,
    nextFrame: () => tester.binding.endOfFrame,
  );
  await windows.start();
  await tester.pumpWidget(
    BaoCodeApp(workspace: workspace, windows: windows),
    wrapWithView: false,
  );
  await tester.pump();
  return (windows, host, workspace);
}

/// Opens [folder]'s window, the frames it takes drawn.
Future<AppWindow> _open(
  WidgetTester tester,
  AppWindows windows,
  String folder, {
  AgentThread? thread,
}) async {
  final opening = windows.showFolder(folder, thread: thread);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return (await opening)!;
}

Finder _inView(int viewId, Finder finder, {bool skipOffstage = true}) =>
    find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is View && widget.view.viewId == viewId,
      ),
      matching: finder,
      skipOffstage: skipOffstage,
    );

/// The desktop semantics check (test/semantics_tree.dart) keeps one tree
/// for all views; the windows' own (their accessibility) are left out.
void _testWindows(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback, semanticsEnabled: false);

void main() {
  _testWindows(
    'closing local chat asks about its hidden IDE and Cancel preserves both',
    (tester) async {
      final (windows, host, workspace) = await _pumpApp(tester);
      final main = workspace.current;
      final mainGrid = List.of(workspace.grid.panes);
      final window = await _open(tester, windows, '~/code/baocode');
      final space = window.delegate!.ideSpace!;
      final document = space.newUntitled();
      space.edit(document.path, 'unsaved editor text');
      await tester.pump();
      expect(document.dirty, isTrue);
      final ide = tester.state<IdeWorkbenchState>(
        _inView(window.viewId, find.byType(IdeWorkbench)),
      );
      await tester.tap(
        _inView(window.viewId, find.byType(BackToChatButton)).first,
      );
      await tester.pump();
      await tester.pump();
      final local = window.thread!;
      local.session.draft.save(
        'unsent local chat',
        const TextSelection.collapsed(offset: 5),
        const [],
      );
      host.log.clear();

      for (var attempt = 0; attempt < 2; attempt++) {
        final closing = windows.requestClose(window);
        await tester.pump();
        expect(_inView(window.viewId, find.text("Don't Save")), findsOneWidget);
        expect(_inView(0, find.text('Cancel')), findsNothing);
        await tester.tap(_inView(window.viewId, find.text('Cancel')));
        await tester.pump();
        expect(await closing, isFalse);
        expect(_inView(window.viewId, find.text('Cancel')), findsNothing);
        expect(windows.ideWindows, contains(window));
        expect(host.log, isNot(contains('close ${window.viewId}')));
        expect(window.chatMode, isTrue);
        expect(window.thread, same(local));
        expect(local.session.draft.content, 'unsent local chat');
        expect(window.delegate!.ideSpace, same(space));
        expect(space.documents, contains(document));
        expect(document.text, 'unsaved editor text');
        expect(document.dirty, isTrue);
        expect(
          tester.state<IdeWorkbenchState>(
            _inView(
              window.viewId,
              find.byType(IdeWorkbench, skipOffstage: false),
              skipOffstage: false,
            ),
          ),
          same(ide),
        );
        expect(workspace.current, same(main));
        expect(workspace.grid.panes, orderedEquals(mainGrid));
      }

      final closing = windows.requestClose(window);
      await tester.pump();
      await tester.tap(_inView(window.viewId, find.text("Don't Save")));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(await closing, isTrue);
      expect(windows.ideWindows, isNot(contains(window)));
      expect(host.log, contains('close ${window.viewId}'));
      expect(host.log, isNot(contains('close ${windows.chat.viewId}')));
      expect(workspace.threads, contains(local));
      expect(local.session.draft.content, 'unsent local chat');
      expect(workspace.current, same(main));
      expect(workspace.grid.panes, orderedEquals(mainGrid));
      expect(tester.takeException(), isNull);
    },
  );

  _testWindows(
    'Back to Chat stays in the new window and keeps its IDE mounted',
    (tester) async {
      final (windows, host, workspace) = await _pumpApp(tester);
      final main = workspace.current;
      final mainGrid = List.of(workspace.grid.panes);
      final window = await _open(tester, windows, '~/code/baocode');
      final space = window.delegate!.ideSpace!;
      final document = space.newUntitled();
      await tester.pump();
      final ide = tester.state<IdeWorkbenchState>(
        _inView(window.viewId, find.byType(IdeWorkbench)),
      );

      await tester.tap(
        _inView(window.viewId, find.byType(BackToChatButton)).first,
      );
      await tester.pump();
      await tester.pump();
      final local = window.thread!;
      expect(window.chatMode, isTrue);
      expect(local, isNot(same(main)));
      expect(host.focused, window.viewId);
      expect(workspace.current, same(main));
      expect(workspace.grid.panes, mainGrid);
      expect(_inView(window.viewId, find.byType(ChatScreen)), findsOneWidget);
      expect(_inView(window.viewId, find.byType(IdeWorkbench)), findsNothing);
      expect(
        tester.state(
          _inView(
            window.viewId,
            find.byType(IdeWorkbench, skipOffstage: false),
            skipOffstage: false,
          ),
        ),
        same(ide),
      );
      expect(window.delegate!.ideSpace, same(space));
      expect(space.documents, contains(document));

      // The same conversation may exist in the hidden IDE and visible chat:
      // each surface needs its own widget key, while its data stays shared.
      workspace.openIdeChat(window.folder!, local);
      ide.showChat();
      for (var round = 0; round < 3; round++) {
        windows.showIdeIn(window);
        await tester.pump();
        await tester.pump();
        await tester.tap(
          _inView(window.viewId, find.byType(BackToChatButton)).first,
        );
        await tester.pump();
        await tester.pump();
        expect(window.thread, same(local));
        expect(window.delegate!.ideSpace, same(space));
        expect(
          _inView(
            window.viewId,
            find.byType(ChatScreen, skipOffstage: false),
            skipOffstage: false,
          ),
          findsNWidgets(2),
        );
        expect(tester.takeException(), isNull);
      }
      expect(workspace.current, same(main));
    },
  );

  _testWindows(
    'local sidebar, project chooser and new chat do not select the main chat',
    (tester) async {
      final (windows, host, workspace) = await _pumpApp(tester);
      final main = workspace.current;
      final window = await _open(tester, windows, '~/code/baocode');
      windows.showChatIn(window);
      await tester.pump();
      await tester.pump();
      final initial = window.thread!;
      initial.session.draft.save(
        'draft only in B',
        const TextSelection.collapsed(offset: 5),
        const [],
      );
      final sidebar = tester.widget<Sidebar>(
        _inView(window.viewId, find.byType(Sidebar)),
      );
      final other = workspace.threads.firstWhere(
        (t) => !identical(t, initial) && !identical(t, main),
      );
      sidebar.onSelect!(other);
      await tester.pump();
      expect(window.thread, same(other));
      expect(workspace.current, same(main));
      expect(initial.session.draft.content, 'draft only in B');
      sidebar.onNewAgent!(initial.project);
      await tester.pump();
      await tester.pump();
      final fresh = window.thread!;
      expect(fresh, isNot(same(initial)));
      expect(fresh.session.draft.content, isNot('draft only in B'));
      expect(workspace.current, same(main));
      final folderBar = tester.widget<NewChatFolderBar>(
        _inView(window.viewId, find.byType(NewChatFolderBar)),
      );
      expect(folderBar.onMove, isNotNull);
      folderBar.onMove!('~/code/cursor-docs');
      await tester.pump();
      expect(window.thread!.project.path, '~/code/cursor-docs');
      expect(workspace.current, same(main));
      expect(host.focused, window.viewId);
    },
  );

  _testWindows(
    'local chat search and editor button keep the chosen conversation',
    (tester) async {
      final (windows, _, workspace) = await _pumpApp(tester);
      final main = workspace.current;
      final window = await _open(tester, windows, '~/code/baocode');
      windows.showChatIn(window);
      await tester.pump();
      await tester.pump();
      final local = window.thread!;
      final button = tester.widget<OpenInEditorButton>(
        _inView(window.viewId, find.byType(OpenInEditorButton)).first,
      );
      expect(button.agent, same(local));
      final context = tester.element(
        _inView(window.viewId, find.byType(OpenInEditorButton)).first,
      );
      OpenInIdeScope.of(context)!(local.project, local);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(window.chatMode, isFalse);
      expect(workspace.ideChat(window.folder!), same(local));
      windows.showChatIn(window);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final palette = tester.widget<SearchPalette>(
        _inView(window.viewId, find.byType(SearchPalette)),
      );
      final chosen = workspace.threads.firstWhere(
        (t) => !identical(t, main) && !identical(t, local),
      );
      palette.onOpenAgent(chosen);
      await tester.pump();
      expect(window.thread, same(chosen));
      expect(workspace.current, same(main));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 200));
    },
  );

  _testWindows('an IDE window is a view of its own: its workbench the IDE, '
      'the chat\'s window without it', (tester) async {
    final (windows, host, workspace) = await _pumpApp(tester);
    expect(find.byType(Workbench), findsOneWidget);
    expect(find.byType(IdeWorkbench), findsNothing);

    final window = await _open(tester, windows, '~/code/baocode');
    expect(find.byType(Workbench), findsNWidgets(2));
    expect(_inView(window.viewId, find.byType(IdeWorkbench)), findsOneWidget);
    expect(_inView(0, find.byType(IdeWorkbench)), findsNothing);
    expect(window.delegate, isNotNull);
    expect(window.delegate!.ideSpace, isNotNull);
    expect(host.titles[window.viewId], 'baocode — BaoCode');

    // Asking the IDE in the chat's window goes to the IDE's.
    workspace.layout = WorkspaceLayout.ide;
    await tester.pump();
    await tester.pump();
    expect(_inView(0, find.byType(IdeWorkbench)), findsNothing);
    expect(host.created, hasLength(1));
  });

  _testWindows('the same agent in both windows is the same, its tab the '
      'IDE\'s chat', (tester) async {
    final (windows, _, workspace) = await _pumpApp(tester);
    final thread = workspace.threads.first;
    final window = await _open(
      tester,
      windows,
      thread.project.path,
      thread: thread,
    );
    workspace.openInIde(thread);
    await tester.pump();
    await tester.pump();
    final title = tester.widget<IdeChatTitle>(
      _inView(window.viewId, find.byType(IdeChatTitle)),
    );
    expect(title.tabs, contains(same(thread)));
    expect(title.current, same(thread));
  });

  _testWindows('an agent\'s window (Open with BaoCode): its agent\'s '
      'conversation, a view of its own; closed, it goes', (tester) async {
    final (windows, host, workspace) = await _pumpApp(tester);
    final opening = windows.openAgent(['~/code/baocode']);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    final thread = (await opening)!;
    final window = windows.agentWindows.single;
    expect(find.byType(Workbench), findsNWidgets(2));
    final chat = _inView(window.viewId, find.byType(ChatScreen));
    expect(chat, findsOneWidget);
    expect(tester.widget<ChatScreen>(chat).session, same(thread.session));
    // Wide, its sidebar is docked, as the chat's window's.
    expect(_inView(window.viewId, find.byType(Sidebar)), findsOneWidget);
    expect(_inView(window.viewId, find.byType(IdeWorkbench)), findsNothing);
    // The chat's window keeps its own.
    expect(_inView(0, find.byType(Sidebar)), findsOneWidget);
    expect(workspace.current, isNot(same(thread)));

    final closing = windows.requestClose(window);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(await closing, isTrue);
    expect(find.byType(Workbench), findsOneWidget);
    expect(host.views, isEmpty);
    expect(workspace.threads, isNot(contains(thread)));
  });

  testWidgets(
    'an agent\'s window has the sidebar, as the chat\'s: '
    'its toggle slides it out while narrow; an agent picked there shows in '
    'the window in place of its own',
    (tester) async {
      final (windows, host, workspace) = await _pumpApp(tester);
      final opening = windows.openAgent(['~/code/baocode']);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      final thread = (await opening)!;
      final window = windows.agentWindows.single;
      host.views[window.viewId]!.physicalSize = const Size(520, 760);
      await tester.pump();
      await tester.pump();
      final sidebar = _inView(window.viewId, find.byType(Sidebar));
      expect(sidebar, findsNothing);

      final current = workspace.current;
      await tester.tap(
        _inView(
          window.viewId,
          find.widgetWithIcon(SidebarIconButton, Codicons.layoutSidebarLeftOff),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sidebar, findsOneWidget);
      expect(tester.widget<Sidebar>(sidebar).current, same(thread));

      final other = workspace.threads.firstWhere(
        (t) => !identical(t, thread) && !t.untouched,
      );
      await tester.tap(
        find.descendant(of: sidebar, matching: find.text(other.title)).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(window.thread, same(other));
      expect(
        tester
            .widget<ChatScreen>(_inView(window.viewId, find.byType(ChatScreen)))
            .session,
        same(other.session),
      );
      expect(host.titles[window.viewId], contains(other.title));
      // The chat's window keeps its own; the new agent nothing was sent to
      // goes, as with its window closed.
      expect(workspace.current, same(current));
      expect(workspace.threads, isNot(contains(thread)));
    },
    semanticsEnabled: false,
    // Its toggle is the header's on Windows, by the traffic lights on macOS.
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  _testWindows('a window closed goes, its view and its workbench', (
    tester,
  ) async {
    final (windows, host, _) = await _pumpApp(tester);
    final window = await _open(tester, windows, '~/code/baocode');
    final closing = windows.requestClose(window);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(await closing, isTrue);
    expect(find.byType(Workbench), findsOneWidget);
    expect(host.views, isEmpty);
    expect(window.delegate, isNull);
  });

  _testWindows('Open Folder in a window builds it anew for the folder', (
    tester,
  ) async {
    final (windows, _, _) = await _pumpApp(tester);
    final window = await _open(tester, windows, '~/code/baocode');
    final before = window.delegate;
    final replacing = windows.replaceFolder(window, '~/code/cursor-docs');
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await replacing;
    expect(window.folder, '~/code/cursor-docs');
    expect(window.delegate, isNotNull);
    expect(window.delegate, isNot(same(before)));
    expect(find.byType(Workbench), findsNWidgets(2));
  });

  _testWindows('Switch Window shows in the window it was asked in', (
    tester,
  ) async {
    final (windows, _, _) = await _pumpApp(tester);
    final window = await _open(tester, windows, '~/code/baocode');
    windows.switchWindow(window);
    await tester.pump();
    await tester.pump();
    expect(
      _inView(window.viewId, find.text('Select a window to switch to')),
      findsOneWidget,
    );
    expect(_inView(0, find.text('Select a window to switch to')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  });

  _testWindows('window.ideWindows switched: the IDE moves into the main '
      'window, and back to a window of its own', (tester) async {
    var settings = const WindowSettings(ideWindows: IdeWindows.separate);
    final (windows, host, _) = await _pumpApp(tester, settings: () => settings);
    final window = await _open(tester, windows, '~/code/baocode');

    settings = const WindowSettings(ideWindows: IdeWindows.mainWindow);
    windows.settingsChanged();
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(windows.multi, isFalse);
    expect(host.views, isEmpty);
    expect(window.delegate, isNull);
    expect(find.byType(Workbench), findsOneWidget);
    expect(_inView(0, find.byType(IdeWorkbench)), findsOneWidget);
    expect(windows.chat.delegate!.ideSpace!.root, '~/code/baocode');

    settings = const WindowSettings(ideWindows: IdeWindows.separate);
    windows.settingsChanged();
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(windows.multi, isTrue);
    expect(host.created, hasLength(2));
    final moved = windows.ideWindows.single;
    expect(moved.folder, '~/code/baocode');
    expect(_inView(moved.viewId, find.byType(IdeWorkbench)), findsOneWidget);
    // The main window's IDE is gone, not only hidden.
    expect(
      _inView(0, find.byType(IdeWorkbench, skipOffstage: false)),
      findsNothing,
    );
  });

  _testWindows('New Window (⇧⌘N) from the default chat opens a native view', (
    tester,
  ) async {
    final (windows, host, _) = await _pumpApp(
      tester,
      settings: () => const WindowSettings(ideWindows: IdeWindows.mainWindow),
    );
    expect(windows.started, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(windows.multi, isTrue);
    expect(host.created, hasLength(1));
    final opened = windows.ideWindows.single;
    expect(_inView(opened.viewId, find.byType(IdeStartPage)), findsOneWidget);
    expect(_inView(0, find.byType(IdeStartPage)), findsNothing);
    expect(find.byType(Workbench), findsNWidgets(2));
  });

  _testWindows('an agent\'s window has the search palette (Ctrl+Shift+P), '
      'its commands the window\'s, Preferences: Color Theme among them', (
    tester,
  ) async {
    final (windows, _, _) = await _pumpApp(tester);
    final opening = windows.openAgent(['~/code/baocode']);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await opening;
    final window = windows.agentWindows.single;
    // The keyboard is the agent's window's (its composer has the focus).
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<View>()
          ?.view
          .viewId,
      window.viewId,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(_inView(window.viewId, find.byType(SearchPalette)), findsOneWidget);
    expect(_inView(0, find.byType(SearchPalette)), findsNothing);
    final palette = tester.widget<SearchPalette>(
      _inView(window.viewId, find.byType(SearchPalette)),
    );
    expect(
      palette.actions.map((action) => action.id),
      contains('workbench.action.selectTheme'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
  });
}
