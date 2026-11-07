import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/quick_ask/quick_ask_agent.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Kernel
    with KernelEventSource
    implements AgentKernel, SelectsModel, SelectsMode, SelectsPermission {
  _Kernel(this.descriptor, this.context) {
    model.reported = context.settings['model'] ?? 'chosen-model';
    mode.reported = context.settings['mode'] ?? 'ask';
    permission.reported = context.settings['permission'] ?? 'read-only';
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext context;
  final sent = <KernelTurn>[];
  bool failSend = false;

  static const _icon = IconData(0xe001);
  @override
  final LocalChoice model = LocalChoice(const [
    KernelOption('chosen-model', 'Chosen model', _icon, ''),
    KernelOption('other-model', 'Other model', _icon, ''),
    KernelOption('@gone/model', 'Missing custom model', _icon, ''),
  ]);
  @override
  final LocalChoice mode = LocalChoice(const [
    KernelOption('agent', 'Agent', _icon, ''),
    KernelOption('ask', 'Ask', _icon, ''),
  ]);
  @override
  final LocalChoice permission = LocalChoice(const [
    KernelOption('read-only', 'Read only', _icon, ''),
    KernelOption('workspace-write', 'Workspace write', _icon, ''),
  ]);
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  String? get sessionId => null;
  @override
  Future<void> get stopped async {}
  @override
  void send(KernelTurn turn) {
    sent.add(turn);
    if (failSend) throw StateError('Uncertain transport outcome');
    emit(ItemUpserted(nextSeq, turn.id, UserMessageItem(text: turn.text)));
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {}
  @override
  void cancel() {}
  @override
  void prepare() {}
  @override
  void release() {}
  @override
  void restart() {}
  @override
  void dispose() => closeEvents();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Workspace workspace;
  late List<_Kernel> runs;
  late KernelDescriptor first;
  late KernelDescriptor second;
  late AgentThread source;
  var failNewSend = false;
  var replaceNewModel = false;

  setUp(() {
    runs = [];
    failNewSend = false;
    replaceNewModel = false;
    KernelDescriptor descriptor(String id) {
      late final KernelDescriptor value;
      value = KernelDescriptor(
        id: id,
        label: id,
        icon: _Kernel._icon,
        description: '',
        create: (context) {
          final run = _Kernel(value, context)..failSend = failNewSend;
          if (replaceNewModel && runs.isNotEmpty) {
            run.model.reported = 'other-model';
          }
          runs.add(run);
          return run;
        },
      );
      return value;
    }

    first = descriptor('codex');
    second = descriptor('claude-code');
    workspace = Workspace(
      projects: const [Project('Chosen', '/tmp/chosen')],
      kernels: [first, second],
    );
    source = workspace.create();
  });

  tearDown(() => workspace.dispose());

  test('fresh submit preserves source draft and never copies history', () {
    source.session.draft.save(
      'Unsent user draft',
      const TextSelection.collapsed(offset: 17),
      const [],
    );
    final handoff = QuickAskAgentHandoff(workspace, source);
    final target = handoff.submit('Bounded selection prompt');

    expect(target, isNotNull);
    expect(target, isNot(same(source)));
    expect(workspace.current, same(source));
    expect(target!.project, source.project);
    expect(target.session.kernelContext.resume, isNull);
    expect(target.session.draft.content, isNull);
    expect(source.session.draft.content, 'Unsent user draft');
    expect(source.session.itemCount, 0);
    expect(runs.first.sent, isEmpty);
    expect(runs.last.sent.single.text, 'Bounded selection prompt');
    expect(runs.last.sent.single.mentions, isEmpty);
    expect(runs.last.sent.single.notes, isEmpty);
    expect(handoff.submit('Do not send twice'), isNull);
    expect(runs.last.sent, hasLength(1));
  });

  test('captured kernel, model and permission survive newer choices', () {
    source.session.setKernel(second);
    final handoff = QuickAskAgentHandoff(workspace, source);
    source.session.models!.onSelected(source.session.models!.options[1]);
    source.session.permissions!.onSelected(
      source.session.permissions!.options.last,
    );
    source.session.setKernel(first);
    final other = workspace.create(
      project: const Project('Other', '/tmp/other'),
    );
    final target = handoff.submit('Act on the original selected project')!;

    expect(workspace.current, same(other));
    expect(target.project.path, '/tmp/chosen');
    expect(target.kernel, same(second));
    expect(runs.last.context.settings['model'], 'chosen-model');
    expect(runs.last.context.settings['permission'], 'read-only');
    expect(runs.last.context.settings['mode'], 'agent');
    expect(target.session.permissions!.selected.id, 'read-only');
    expect(other.session.itemCount, 0);
  });

  test(
    'deleted, archived or moved sources never fall back to another project',
    () {
      final handoff = QuickAskAgentHandoff(workspace, source);
      source.project = const Project('Moved', '/tmp/moved');
      expect(handoff.submit('Wrong location'), isNull);
      source.project = const Project('Chosen', '/tmp/chosen');
      source.archived = true;
      expect(handoff.submit('Archived'), isNull);
      source.archived = false;
      workspace.delete(source);
      workspace.create(project: const Project('Other', '/tmp/other'));
      final count = runs.length;
      expect(handoff.submit('Deleted'), isNull);
      expect(runs, hasLength(count));
      expect(runs.every((run) => run.sent.isEmpty), isTrue);
    },
  );

  test('a normalized destination model never receives the selection', () {
    final handoff = QuickAskAgentHandoff(workspace, source);
    replaceNewModel = true;
    expect(handoff.submit('Private selected text'), isNull);
    expect(runs, hasLength(2));
    expect(runs.last.context.preserveModel, isTrue);
    expect(runs.every((run) => run.sent.isEmpty), isTrue);
    expect(handoff.submit('Do not retry'), isNull);
    expect(runs, hasLength(2));
  });

  test('an uncertain send cannot create or dispatch a duplicate', () {
    final handoff = QuickAskAgentHandoff(workspace, source);
    failNewSend = true;
    expect(handoff.submit('First attempt'), isNull);
    expect(runs.last.sent, hasLength(1));
    final count = runs.length;
    expect(handoff.submit('Retry must not send'), isNull);
    expect(runs, hasLength(count));
    expect(runs.last.sent, hasLength(1));
    expect(source.session.itemCount, 0);
  });

  test(
    'missing captured custom provider never falls back to another model',
    () {
      source.session.models!.onSelected(source.session.models!.options.last);
      final handoff = QuickAskAgentHandoff(workspace, source);
      final count = runs.length;
      expect(handoff.submit('Private selected text'), isNull);
      expect(runs, hasLength(count));
      expect(runs.every((run) => run.sent.isEmpty), isTrue);
    },
  );

  test(
    'fresh agent does not erase the persisted project draft before ID',
    () async {
      workspace.dispose();
      final drafts = MemoryPreferenceStore();
      workspace = Workspace(
        projects: const [Project('Chosen', '/tmp/chosen')],
        kernels: [first],
        drafts: drafts,
      );
      source = workspace.create();
      source.session.draft.save(
        'Keep me',
        const TextSelection.collapsed(offset: 7),
        const [],
      );
      final target = QuickAskAgentHandoff(workspace, source).submit('Act')!;
      target.session.draft.save(
        '',
        const TextSelection.collapsed(offset: 0),
        const [],
      );
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect((drafts.preferences['new:/tmp/chosen'] as Map)['text'], 'Keep me');
    },
  );
}
