import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../../chat/review/unpatch.dart';
import '../../icons/brand_logos.dart';
import '../../models/launch_environment.dart'
    show ProxyEndpoint, fastModelSuffix;
import '../../models/model_icons.dart';
import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../../models/model_runtime.dart';
import '../../remote/project_host.dart';
import '../../settings/user_settings.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../agent_kernel.dart';
import '../claude_code/claude_elicitation.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import '../prompt_suggestions.dart';
import 'codex_process_transport.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel].
///
/// Its `thread/revert` only rewinds the conversation, so the files are put
/// back here, from the patches it applied. Everything else the app shows it
/// declares, as far as the protocol supports it.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        ConfirmsModelSwitch,
        SelectsMode,
        StartsPlans,
        SelectsPermission,
        SelectsEffort,
        SelectsFast,
        ProvidesCommands,
        ReportsContext,
        ReportsUsage,
        ReportsUsageLimit,
        QueuesMessages,
        RewindsConversation,
        RevertsChanges,
        ForksConversation,
        RenamesSession,
        AcceptsImages,
        LoadsHistory,
        SuggestsPrompts,
        ManagesMcpServers,
        RunsBackgroundTasks,
        SuggestsFiles {
  CodexKernel(
    this.descriptor,
    this._context, {
    CodexTransportFactory? start,
    ModelProviders? providers,
    Future<ProxyEndpoint?> Function()? providerProxy,
  }) : _start = start ?? startCodexProcess,
       _providers = providers ?? ModelProviders.current,
       _proxy = providerProxy ?? codexProxyEndpoint {
    _providers.addListener(_providersChanged);
    _sessionId = _context.resume?.id;
    final settings = _context.settings;
    _modelId = settings[KernelChoiceKind.model.name];
    _effort = settings[KernelChoiceKind.effort.name];
    _modeId = _pick(settings[KernelChoiceKind.mode.name], _modes, 'agent');
    _permissionId = _pick(
      settings[KernelChoiceKind.permission.name],
      _permissions,
      'workspace-write',
    );
    _fast = settings[KernelChoiceKind.fast.name] == 'fast';
    final efforts = '${KernelChoiceKind.effort.name}@';
    final singles = '${KernelChoiceKind.fast.name}@';
    for (final MapEntry(:key, :value) in settings.entries) {
      if (key.startsWith(efforts)) {
        _pickedEfforts[key.substring(efforts.length)] = value;
      } else if (key.startsWith(singles)) {
        _pickedFast[key.substring(singles.length)] = value == 'fast';
      }
    }
    // The models it last listed, until its own list arrives: the picker is
    // right from the start, as Claude Code's is.
    _useCachedModels();
    // What is in effect is reported as it is, not left to the first option.
    (model as LocalChoice).reported = _modelId;
    (mode as LocalChoice).reported = _modeId;
    (permission as LocalChoice).reported = _permissionId;
  }

  /// A kernel over [transport] as it is, e.g. a stand-in under test.
  factory CodexKernel.withTransport(
    KernelDescriptor descriptor,
    CodexTransport transport, {
    KernelContext context = const KernelContext(),
    ModelProviders? providers,
    Future<ProxyEndpoint?> Function()? providerProxy,
  }) => CodexKernel(
    descriptor,
    context,
    start: (_) async => transport,
    providers: providers,
    providerProxy: providerProxy,
  );

  static String _pick(
    String? wanted,
    List<KernelOption> options,
    String fallback,
  ) {
    if (wanted != null && options.any((option) => option.id == wanted)) {
      return wanted;
    }
    return options.any((option) => option.id == fallback)
        ? fallback
        : options.first.id;
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final CodexTransportFactory _start;

  /// The models BaoCode manages (Settings → Models), whose picker goes
  /// beside the server's own.
  final ModelProviders _providers;

  /// Where a session on one of them sends its requests: this machine's
  /// proxy, which asks the provider ([ModelProxy]).
  final Future<ProxyEndpoint?> Function() _proxy;

  @override
  late final KernelChoiceSource model = LocalChoice(
    _modelOptions,
    onChanged: (id) {
      _modelId = id;
      // Another model may not take the effort this one does.
      _settleSettings(id);
      emitInfoChanged();
    },
  );

  @override
  late final KernelChoiceSource mode = LocalChoice(
    _modes,
    onChanged: (id) {
      _modeId = id;
      emitInfoChanged();
    },
  );

  @override
  late final KernelChoiceSource permission = LocalChoice(
    _permissions,
    onChanged: (id) {
      _permissionId = id;
      emitInfoChanged();
    },
  );

  @override
  late final ModelSetting effort = _EffortSetting(this);

  @override
  late final ModelSetting fast = _FastSetting(this);

  /// Where the server's models are kept between runs (main.dart sets it),
  /// so the picker lists them before the server has started (it starts
  /// with the first message). As it last listed them.
  static GlobalStorage? get modelCache => _modelCache;
  static set modelCache(GlobalStorage? storage) => _modelCache = storage;

  static GlobalStorage? _modelCache;
  static const modelCacheKey = 'codex.models';

  /// The server's models, as it listed them; empty until it has.
  final List<KernelOption> _models = [];

  /// What the picker shows: [_models], or one Default until they are known
  /// (the model picked, if it is, or the server's own). Never a model the
  /// app only guesses at.
  final List<KernelOption> _modelOptions = [];
  final Map<String, List<KernelOption>> _effortsByModel = {};
  final Map<String, String?> _defaultEfforts = {};
  final Map<String, String> _pickedEfforts = {};

  /// The service tiers each model takes, by the tier id the server names
  /// (the standard one left out: that is the default).
  final Map<String, List<KernelOption>> _tiersByModel = {};
  final Map<String, bool> _pickedFast = {};
  bool _fast = false;
  String? _modelId;

  /// The model as the server takes it: none for Default, which leaves the
  /// pick to the server's own; one of BaoCode's as its proxy names it
  /// ([modelRef]), with the effort and fast mode the proxy reads off it.
  String? get _modelForServer {
    final id = _modelId;
    if (id == null || id == 'default') return null;
    if (_providers.resolve(id) case (final provider, final info)) {
      final effort = _effort;
      final fast = _fast && _offersFast(provider, info);
      return modelRef(
        provider.id,
        effort == null && !fast
            ? info.id
            : '${info.id}(${effort ?? ''}${fast ? fastModelSuffix : ''})',
      );
    }
    return id;
  }

  /// The provider and model the pick is, if it is one of BaoCode's.
  (ModelProvider, ProviderModel)? get _custom => _providers.resolve(_modelId);

  /// What a session on one of BaoCode's models goes through: the proxy's
  /// provider id, as the thread's `modelProvider`.
  static const _proxyProviderId = 'baocode';

  /// Whether [info] of [provider] takes fast mode: Responses' models,
  /// whose tier the proxy sets, or its models' names.
  static bool _offersFast(ModelProvider provider, ProviderModel info) =>
      switch (provider.protocolOf(info)) {
        ProviderProtocol.openaiResponses || ProviderProtocol.codex => true,
        _ => false,
      };

  /// [id] picked: the effort and fast mode it takes, its own, or what the
  /// server said of it.
  void _settleSettings(String id) {
    if (_providers.resolve(id) case (final provider, final info)) {
      final levels = info.effortLevels;
      final wanted = _pickedEfforts[id] ?? _effort;
      _effort = levels.contains(wanted) ? wanted : info.initialEffort;
      _fast = (_pickedFast[id] ?? false) && _offersFast(provider, info);
      // Fast goes in the model's name for these: no service tier of the
      // server's own.
      _fastTier = null;
      _contextWindow = info.initialContext;
      return;
    }
    final supported = _effortsByModel[id] ?? const <KernelOption>[];
    final wanted = _pickedEfforts[id] ?? _defaultEfforts[id];
    if (supported.isEmpty) {
      _effort = null;
    } else if (wanted != null &&
        supported.any((option) => option.id == wanted)) {
      _effort = wanted;
    } else {
      _effort = _defaultEfforts[id] ?? supported.first.id;
    }
    // Its fast mode is the model's own too.
    final tiers = _tiersByModel[id] ?? const <KernelOption>[];
    _fast = (_pickedFast[id] ?? false) && tiers.isNotEmpty;
    _fastTier = _fast ? tiers.first.id : null;
  }

  String? _effort;
  String? _fastTier;
  late String _modeId;
  late String _permissionId;

  static const _modes = [
    KernelOption(
      'agent',
      'Agent',
      Icons.all_inclusive_rounded,
      'Edit the workspace, ask before commands',
    ),
    KernelOption(
      'plan',
      'Plan',
      Icons.checklist_rounded,
      'Plan first; build once you start it',
    ),
    KernelOption(
      'ask',
      'Ask',
      Icons.chat_bubble_outline_rounded,
      'Read-only: answer questions',
    ),
  ];

  static const _permissions = [
    KernelOption(
      'read-only',
      'Read only',
      Icons.visibility_outlined,
      'Read files; no edits or commands',
    ),
    KernelOption(
      'workspace-write',
      'Workspace write',
      Icons.edit_outlined,
      'Edit the project; ask before commands',
    ),
    KernelOption(
      'danger-full-access',
      'Full access',
      Icons.warning_amber_rounded,
      'Edit anywhere, and run commands without asking',
      caution: true,
    ),
  ];

  @override
  final List<KernelCommand> commands = const [
    KernelCommand(
      'review',
      'Review uncommitted changes',
      Icons.rate_review_outlined,
    ),
    KernelCommand(
      'init',
      'Write an AGENTS.md for this project',
      Icons.description_outlined,
    ),
    KernelCommand('diff', 'Show the git diff', Icons.difference_outlined),
  ];

  /// What a command the CLI would take turns into for the model.
  static String _prompt(String text) {
    final trimmed = text.trim();
    final name = trimmed.split(RegExp(r'\s')).first;
    final rest = trimmed.substring(name.length).trim();
    return switch (name) {
      '/review' => [
        'Review the uncommitted changes in this workspace.',
        if (rest.isNotEmpty) rest,
        'Report bugs, regressions and missed edge cases, with file and line.',
      ].join('\n\n'),
      '/init' => [
        'Write an AGENTS.md at the root of this project: how to build it,',
        'test it, and the conventions it follows, from what is here.',
        if (rest.isNotEmpty) rest,
      ].join('\n\n'),
      '/diff' => [
        'Show the git diff of the uncommitted changes in this workspace,',
        'and explain what each change does.',
        if (rest.isNotEmpty) rest,
      ].join('\n\n'),
      _ => text,
    };
  }

  // --- State ----------------------------------------------------------------

  CodexTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _starting;

  KernelHealth _health = KernelHealth.idle;
  String? _sessionId;
  String? _threadId;

  /// The provider the thread runs on ([_providerOf]).
  String _threadProvider = '';
  bool _initialized = false;
  bool _disposed = false;
  bool _released = false;

  int _requests = 0;
  final Map<int, Completer<Map<String, Object?>>> _responses = {};

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};
  final List<String> _queue = [];
  final Map<String, KernelTurn> _turns = {};
  String? _nowNext;

  int _contextWindow = 272000;
  List<RateLimitWindow> _limits = const [];
  PromptCache? _cache;
  DateTime? _limitResetsAt;
  bool _usageLimited = false;

  final Set<String> _stoppedTurns = {};
  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};
  final Map<String, Map<String, Object?>> _commands = {};
  final Map<String, Map<String, Object?>> _mcpCalls = {};
  final Map<String, StringBuffer> _commandOutput = {};
  final Map<String, DateTime> _startedAt = {};
  final Map<String, String> _turnOfItem = {};

  /// The turns this kernel began, by the server's id for them: what their
  /// messages are shown under, so reading the conversation back updates
  /// them rather than adding them again.
  final Map<String, String> _clientTurns = {};
  final Map<String, Object?> _approvals = {};

  /// Server requests that take more than a yes or a no: an MCP form, the
  /// agent's questions, additional permissions.
  final Map<String, _Ask> _asks = {};

  String? _planId;
  String? _planText;

  /// The message that would come next, as the server predicted it.
  String? _suggestion;

  /// The MCP servers, as last reported.
  List<McpServer>? _servers;

  /// The commands the server runs in the background, as last listed.
  List<KernelTask> _tasks = const [];

  /// The files changed in each turn of this run, newest turn last, to put
  /// them back.
  final Map<String, List<_EditedFile>> _editsByTurn = {};
  final List<String> _turnsRun = [];

  /// Where the next page of older turns starts; null at the first kept.
  String? _turnsCursor;
  Future<void>? _earlierLoad;

  @override
  String? get sessionId => _sessionId;

  @override
  KernelHealth get health => _health;

  @override
  Future<void> get stopped => _stopped;
  Future<void> _stopped = Future.value();

  @override
  int get contextWindow => _contextWindow;

  @override
  List<RateLimitWindow> get accountLimits => _limits;

  @override
  DateTime? get usageLimitResetsAt => _usageLimited ? _limitResetsAt : null;

  /// The plan's, for the server's own models; one of BaoCode's is its
  /// provider's to limit.
  @override
  bool get usageLimitApplies => parseModelRef(_modelId) == null;

  @override
  bool usageLimitAppliesTo(String model) => parseModelRef(model) == null;

  @override
  bool get loadingHistory => _loadingHistory;
  bool _loadingHistory = false;

  @override
  bool get hasEarlierHistory => _turnsCursor != null && !_loadingHistory;

  @override
  bool get loadingEarlier => _earlierLoad != null;

  @override
  String? get promptSuggestion => _suggestion;

  @override
  List<McpServer>? get mcpServers => _servers;

  @override
  bool get canFork => _threadId != null && _turn == null;

  /// The project as its host spells it: `ssh://` locations are the
  /// server's paths there.
  String? get _projectPath {
    final cwd = _context.cwd ?? _context.resume?.cwd;
    return cwd == null ? null : ProjectHost.of(cwd).pathOf(cwd);
  }

  ProjectHost get _host =>
      ProjectHost.of(_context.cwd ?? _context.resume?.cwd ?? '');

  /// `never` where nothing is to be asked: read-only sandboxes turn the
  /// commands down anyway, and full access is the user's say-so.
  String get _approvalPolicy =>
      _modeId == 'ask' ||
          _modeId == 'plan' ||
          _permissionId == 'read-only' ||
          _permissionId == 'danger-full-access'
      ? 'never'
      : 'on-request';

  String get _sandboxMode =>
      _modeId == 'ask' || _modeId == 'plan' ? 'read-only' : _permissionId;

  Map<String, Object?> get _sandboxPolicy => switch (_sandboxMode) {
    'read-only' => const {'type': 'readOnly'},
    'danger-full-access' => const {'type': 'dangerFullAccess'},
    _ => const {'type': 'workspaceWrite'},
  };

  // --- Lifecycle -------------------------------------------------------------

  @override
  void prepare() {
    if (_disposed || _health.status == KernelHealthStatus.ready) return;
    unawaited(_ensureStarted().catchError((Object _) {}));
  }

  @override
  void release() {
    if (_disposed || _turn != null || _starting != null) return;
    _teardown();
    _released = true;
    _setHealth(KernelHealth.idle);
  }

  @override
  void restart() {
    if (_disposed) return;
    final turn = _turn;
    _teardown();
    _starting = null;
    if (turn != null) {
      _endTurn(turn, interrupted: true);
    }
    _setHealth(KernelHealth.idle);
    unawaited(_ensureStarted().catchError((Object _) {}));
  }

  void _teardown() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _transport?.close();
    _transport = null;
    _initialized = false;
    final stopped = StateError('Codex stopped');
    for (final response in _responses.values) {
      if (!response.isCompleted) response.completeError(stopped);
    }
    _responses.clear();
  }

  Future<void> _ensureStarted() {
    if (_transport != null && _initialized && !_released) {
      return Future.value();
    }
    if (_starting case final starting?) return starting;
    return _starting = _open().whenComplete(() => _starting = null);
  }

  Future<void> _open() async {
    _released = false;
    _setHealth(const KernelHealth(KernelHealthStatus.starting));
    try {
      final transport = await _start(
        CodexLaunch(
          cwd: _context.cwd ?? _context.resume?.cwd ?? '',
          resume: _sessionId,
          model: _modelForServer,
          approvalPolicy: _approvalPolicy,
          sandbox: _sandboxMode,
          effort: _effort,
        ),
      );
      if (_disposed) {
        transport.close();
        return;
      }
      _transport = transport;
      _stopped = transport.exited;
      _subscription = transport.messages.listen(
        (message) => _receive(message, transport),
      );
      // An older process ending later must not unset the one now running.
      unawaited(transport.exited.then((_) => _transportGone(transport)));
      await _request('initialize', {
        'clientInfo': {'name': 'baocode', 'version': '1.0.0'},
        // The MCP list, predictions, file search and paging are behind it.
        'capabilities': {'experimentalApi': true},
      });
      _initialized = true;
      await _loadModels();
      // A new chat starts its thread with its first message, so no empty
      // one is kept for a chat the user only looked at.
      if (_sessionId != null) await _resumeThread();
      _setHealth(KernelHealth.ready);
    } on CodexFolderGone catch (error) {
      _teardown();
      _setHealth(
        KernelHealth(KernelHealthStatus.failed, missingFolder: error.folder),
      );
      rethrow;
    } on CodexUnavailable catch (error) {
      _teardown();
      _setHealth(
        KernelHealth(
          KernelHealthStatus.failed,
          message: error.message,
          detail: error.detail,
        ),
      );
      rethrow;
    } on Object catch (error) {
      _teardown();
      _setHealth(
        KernelHealth(
          KernelHealthStatus.failed,
          message: 'Codex could not start',
          detail: '$error',
        ),
      );
      rethrow;
    }
  }

  void _setHealth(KernelHealth health) {
    _health = health;
    if (!_disposed) emitInfoChanged();
  }

  void _transportGone(CodexTransport gone) {
    if (_disposed || !identical(_transport, gone)) return;
    _transport = null;
    _initialized = false;
    final stopped = StateError('Codex stopped');
    for (final response in _responses.values) {
      if (!response.isCompleted) response.completeError(stopped);
    }
    _responses.clear();
    _setHealth(
      const KernelHealth(
        KernelHealthStatus.failed,
        message: 'Codex stopped',
        detail: 'The app-server process ended.',
      ),
    );
    if (_turn case final turn?) _endTurn(turn, interrupted: true);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _providers.removeListener(_providersChanged);
    _teardown();
    closeEvents();
  }

  // --- Requests --------------------------------------------------------------

  /// [params] null for a request that takes none, which the server wants
  /// left out rather than sent as an empty object.
  Future<Map<String, Object?>> _request(
    String method, [
    Map<String, Object?>? params = const {},
  ]) {
    final transport = _transport;
    if (transport == null) {
      return Future.error(StateError('Codex is not running'));
    }
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    transport.write({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    return response.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _responses.remove(id);
        throw const CodexUnavailable('Codex is not responding');
      },
    );
  }

  Future<void> _loadModels() async {
    final List data;
    try {
      data = (await _request('model/list'))['data'] as List? ?? const [];
    } on Object {
      // No ChatGPT account for the server's own models (a session on one
      // of BaoCode's, or not signed in): what is offered stays so.
      return;
    }
    // A server that lists none leaves what is offered in place.
    if (!data.any((raw) => raw is Map)) return;
    _useModels(data, remember: true);
  }

  /// What the last run's server listed, if it did: the picker is right
  /// before this run's server has started.
  void _useCachedModels() {
    final kept = _modelCache?.get<List<Object?>>(modelCacheKey);
    if (kept != null) {
      _useModels(kept, remember: false, emit: false);
      return;
    }
    _syncModelOptions();
  }

  void _useModels(
    List<Object?> data, {
    required bool remember,
    bool emit = true,
  }) {
    final parsed = _parseModels(data);
    if (parsed.models.isEmpty) return;
    _models
      ..clear()
      ..addAll(parsed.models);
    _effortsByModel
      ..clear()
      ..addAll(parsed.efforts);
    _defaultEfforts
      ..clear()
      ..addAll(parsed.defaults);
    _tiersByModel
      ..clear()
      ..addAll(parsed.tiers);
    if (remember) _keepModels(data);
    _syncModelOptions();
    final wanted = _modelId;
    final chosen = _modelOptions.any((option) => option.id == wanted)
        ? wanted!
        : _modelOptions.first.id;
    _modelId = chosen;
    if (emit) {
      model.select(chosen);
    } else {
      (model as LocalChoice).reported = chosen;
      _settleSettings(chosen);
    }
    // What another kernel kept (a model's effort, say) may not be one this
    // model takes: it starts at what the model does take.
    for (final entry in [..._pickedEfforts.entries]) {
      final options = _effortsByModel[entry.key];
      if (options != null &&
          options.isNotEmpty &&
          !options.any((option) => option.id == entry.value)) {
        _pickedEfforts.remove(entry.key);
      }
    }
    _settleSettings(chosen);
    if (emit) emitInfoChanged();
  }

  void _syncModelOptions() {
    _modelOptions
      ..clear()
      ..addAll([
        ...(_models.isNotEmpty
            ? _models
            : [
                if (_modelId case final id?
                    when id != 'default' && parseModelRef(id) == null)
                  KernelOption(
                    id,
                    id,
                    Icons.bolt_rounded,
                    '',
                    group: _builtinGroup,
                    iconBuilder: _modelIcon(_builtinProvider, id),
                  )
                else
                  KernelOption(
                    'default',
                    'Default',
                    Icons.bolt_rounded,
                    '',
                    group: _builtinGroup,
                    iconBuilder: _modelIcon(_builtinProvider, 'default'),
                  ),
              ]),
        // BaoCode's own: the same models Claude Code runs, each in its
        // provider's group.
        for (final provider in _providers.enabled)
          for (final info in provider.enabledModels)
            KernelOption(
              modelRef(provider.id, info.id),
              info.displayName,
              Icons.hub_outlined,
              [
                info.id,
                if (info.contextWindow case final tokens?) formatTokens(tokens),
              ].join(' · '),
              group: KernelOptionGroup(
                provider.id,
                provider.name,
                warning: _providers.error(provider.id),
                iconBuilder: _providerIcon(provider.id),
              ),
              iconBuilder: _modelIcon(provider.id, info.id),
            ),
      ]);
  }

  /// The server's own models' heading, and the id their icons are drawn
  /// for.
  static const _builtinProvider = 'codex';

  static final _builtinGroup = KernelOptionGroup(
    _builtinProvider,
    'Codex',
    iconBuilder: (size, color) => BrandLogo('openai', size: size, color: color),
  );

  /// Provider [id]'s icon, as its models' heading shows it.
  static Widget Function(double, Color) _providerIcon(String id) =>
      (size, color) => ProviderIcon(id, size: size, color: color);

  /// [model]'s of [provider], as its option shows it.
  static Widget Function(double, Color) _modelIcon(
    String provider,
    String model,
  ) =>
      (size, color) =>
          ModelIcon(provider: provider, model: model, size: size, color: color);

  /// Settings → Models changed: the picker as it is now, and a pick whose
  /// provider is gone falling back to what is offered.
  void _providersChanged() {
    if (_disposed) return;
    _syncModelOptions();
    final picked = _modelId;
    if (picked != null && !_modelOptions.any((option) => option.id == picked)) {
      final fallback = _modelOptions.firstOrNull?.id;
      if (fallback != null) {
        _modelId = fallback;
        _settleSettings(fallback);
        model.select(fallback);
      }
    }
    emitInfoChanged();
  }

  /// The provider [model] belongs to: '' for the server's own, else the
  /// provider's ([modelRef]).
  static String _providerOf(String? model) => switch (parseModelRef(model)) {
    (:final provider, model: _) => provider,
    null => '',
  };

  /// Whether the conversation has begun: going on with it on the other
  /// side of BaoCode (the server's own models, or its providers') is a
  /// restart, the server keeping a thread to the side it began on.
  bool get _conversationStarted =>
      _sentTurns.isNotEmpty || _context.resume != null;

  /// Whether a thread on provider [on] can go on with [model] as it is:
  /// one of BaoCode's models and another go through the proxy alike (its
  /// model naming the upstream); one of the server's own does not.
  static bool _sameWay(String on, String model) =>
      on.isEmpty == _providerOf(model).isEmpty;

  @override
  bool switchRestarts(String model) =>
      _conversationStarted &&
      !_sameWay(
        _threadId != null ? _threadProvider : _providerOf(_modelId),
        model,
      );

  static ({
    List<KernelOption> models,
    Map<String, List<KernelOption>> efforts,
    Map<String, String?> defaults,
    Map<String, List<KernelOption>> tiers,
  })
  _parseModels(List<Object?> data) {
    final models = <KernelOption>[];
    final effortsByModel = <String, List<KernelOption>>{};
    final defaultEfforts = <String, String?>{};
    final tiersByModel = <String, List<KernelOption>>{};
    for (final raw in data) {
      if (raw is! Map) continue;
      final id = (raw['id'] ?? raw['model']) as String?;
      if (id == null || id.isEmpty) continue;
      models.add(
        KernelOption(
          id,
          raw['displayName'] as String? ?? id,
          Icons.bolt_rounded,
          raw['description'] as String? ?? '',
          group: _builtinGroup,
          iconBuilder: _modelIcon(_builtinProvider, id),
        ),
      );
      final efforts = <KernelOption>[];
      for (final entry
          in raw['supportedReasoningEfforts'] as List? ?? const []) {
        if (entry is! Map) continue;
        final effort = entry['reasoningEffort'] as String?;
        if (effort == null) continue;
        efforts.add(
          KernelOption(
            effort,
            _effortLabel(effort),
            Icons.speed_rounded,
            entry['description'] as String? ?? '',
          ),
        );
      }
      effortsByModel[id] = efforts;
      defaultEfforts[id] =
          raw['defaultReasoningEffort'] as String? ?? efforts.firstOrNull?.id;
      // A tier the model takes besides the standard one is its fast mode.
      final tiers = <KernelOption>[];
      for (final entry in raw['serviceTiers'] as List? ?? const []) {
        if (entry is! Map) continue;
        final tier = entry['id'] as String?;
        if (tier == null || tier.isEmpty || tier == 'default') continue;
        tiers.add(
          KernelOption(
            tier,
            entry['name'] as String? ?? tier,
            Icons.bolt_rounded,
            entry['description'] as String? ?? '',
          ),
        );
      }
      tiersByModel[id] = tiers;
    }
    return (
      models: models,
      efforts: effortsByModel,
      defaults: defaultEfforts,
      tiers: tiersByModel,
    );
  }

  /// Keeps [data] (the server's models, as listed) for the picker at the
  /// next run's start, when they changed.
  static void _keepModels(List<Object?> data) {
    final storage = _modelCache;
    if (storage == null) return;
    final kept = storage.get<List<Object?>>(modelCacheKey);
    if (kept != null && jsonEncode(kept) == jsonEncode(data)) return;
    unawaited(
      storage
          .set(modelCacheKey, data)
          .catchError(
            (Object error) => debugPrint('$modelCacheKey not kept: $error'),
          ),
    );
  }

  static String _effortLabel(String id) => switch (id) {
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'Extra high',
    'max' => 'Max',
    'ultra' => 'Ultra',
    _ => id,
  };

  /// The `modelProvider` and `config` a thread of the model now picked is
  /// begun with: the proxy BaoCode's models go through, and how it asks
  /// them. Null for the server's own models.
  Future<({String modelProvider, Map<String, Object?> config})?>
  _proxyThread() async {
    final custom = _custom;
    if (custom == null) return null;
    final (provider, info) = custom;
    final endpoint = await _proxy();
    if (endpoint == null) {
      throw CodexUnavailable('${provider.name} needs BaoCode\'s model proxy');
    }
    return (
      modelProvider: _proxyProviderId,
      config: {
        'model_providers': {
          _proxyProviderId: {
            'name': 'BaoCode',
            'base_url': '${endpoint.baseUrl}/v1',
            'wire_api': 'responses',
            'experimental_bearer_token': endpoint.token,
            'supports_websockets': false,
          },
        },
        'model_context_window': info.initialContext,
        // The server's own tools go to OpenAI, unasked: an upstream of
        // another's would refuse them.
        'web_search': 'disabled',
        'features': {'multi_agent': false, 'goals': false},
      },
    );
  }

  /// The thread [threadId] as a copy of itself on the provider the model
  /// now picked is of, its id the conversation's from here on: the server
  /// keeps a thread to the provider it began on, a resume on another
  /// staying on its own.
  Future<void> _forkToProvider(String threadId) async {
    final proxied = await _proxyThread();
    final Map<String, Object?>? thread;
    try {
      final result = await _request('thread/fork', {
        'threadId': threadId,
        // None for Default: the server's own pick.
        if (_modelForServer case final model?) 'model': model,
        if (proxied != null) 'modelProvider': proxied.modelProvider,
        if (proxied != null) 'config': proxied.config,
      });
      thread = (result['thread'] as Map?)?.cast<String, Object?>();
    } on CodexRpcError catch (error) {
      // A thread no turn ran on is nothing to copy: begun again on the
      // provider picked (see [_ensureThread]).
      if (!error.message.toLowerCase().contains('no rollout')) rethrow;
      _threadId = null;
      _sessionId = null;
      _threadProvider = '';
      return;
    }
    final id = thread?['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const CodexUnavailable(
        'Codex could not go on with another provider',
      );
    }
    _threadId = id;
    _sessionId = id;
    _threadProvider = _providerOf(_modelId);
  }

  Future<void> _startThread() async {
    final proxied = await _proxyThread();
    final result = await _request('thread/start', {
      if (_projectPath case final cwd?) 'cwd': cwd,
      if (_modelForServer case final model?) 'model': model,
      if (proxied != null) 'modelProvider': proxied.modelProvider,
      if (proxied != null) 'config': proxied.config,
      if (proxied == null)
        if (_fastTier case final tier?) 'serviceTier': tier,
      'approvalPolicy': _approvalPolicy,
      'sandbox': _sandboxMode,
    });
    _applyThread((result['thread'] as Map?)?.cast<String, Object?>());
    _applyTier(result['serviceTier']);
  }

  Future<void> _resumeThread() async {
    final id = _sessionId;
    if (id == null) return _startThread();
    final proxied = await _proxyThread();
    final result = await _request('thread/resume', {
      'threadId': id,
      if (_projectPath case final cwd?) 'cwd': cwd,
      if (_modelForServer case final model?) 'model': model,
      if (proxied != null) 'modelProvider': proxied.modelProvider,
      if (proxied != null) 'config': proxied.config,
      if (proxied == null)
        if (_fastTier case final tier?) 'serviceTier': tier,
      'approvalPolicy': _approvalPolicy,
      'sandbox': _sandboxMode,
    });
    final thread = (result['thread'] as Map?)?.cast<String, Object?>();
    _applyThread(thread);
    _applyTier(result['serviceTier']);
    // A server of before returns the whole conversation with it; a newer
    // one pages it (thread/turns/list), the rest on asking.
    final turns = thread?['turns'] as List?;
    final backwards = result['turnsBackwardsCursor'] as String?;
    _turnsCursor = backwards == null || backwards.isEmpty ? null : backwards;
    if (turns != null && turns.isNotEmpty) {
      await _replay(turns);
    } else {
      try {
        await _loadTurnsPage(initial: true);
      } on Object {
        // A server without paged turns keeps no earlier history to show.
      }
    }
    unawaited(_refreshTasks());
  }

  void _applyThread(Map<String, Object?>? thread) {
    if (thread == null) return;
    _threadId = thread['id'] as String?;
    // The thread is what the catalog lists and resume takes, not the
    // session the server keeps with it.
    _sessionId = _threadId;
    final model = thread['model'] as String?;
    if (model != null && model.isNotEmpty) {
      // One of BaoCode's comes back as its proxy is asked for it: with
      // the effort after it, which the pick has already.
      final open = model.lastIndexOf('(');
      final plain = open > 0 && model.endsWith(')')
          ? model.substring(0, open)
          : model;
      _modelId = parseModelRef(plain) != null ? plain : model;
      if (_modelOptions.any((option) => option.id == _modelId)) {
        this.model.select(_modelId!);
      }
    }
    final effort = thread['reasoningEffort'] as String?;
    if (effort != null) _effort = effort;
    // The provider it is on, as the server keeps it: a resume asks for
    // another, and stays on the thread's own.
    final provider = thread['modelProvider'] as String?;
    _threadProvider = switch (provider) {
      final id? when id == _proxyProviderId => _providerOf(_modelId),
      final id? when id.isNotEmpty => '',
      // An older server says none: the model's own.
      _ => _providerOf(_modelId),
    };
  }

  /// The tier the thread runs on, as the server reports it beside it.
  void _applyTier(Object? raw) {
    // BaoCode's models: fast is in the model's name, not a tier.
    if (_custom != null) return;
    if (raw is! String) return;
    _fast = raw != 'default';
    _fastTier = _fast ? raw : null;
  }

  // --- Sending ---------------------------------------------------------------

  @override
  void send(KernelTurn turn) {
    if (_disposed || !_sentTurns.add(turn.id)) return;
    _turns[turn.id] = turn;
    _usageLimited = false;
    if (_suggestion != null) {
      _suggestion = null;
      emitInfoChanged();
    }
    final busy = _turn != null;
    if (busy) {
      _queue.add(turn.id);
    } else {
      _beginTurn(turn.id);
    }
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(
          text: turn.text,
          queued: busy,
          images: turn.images,
          sentAt: DateTime.now(),
        ),
      ),
    );
    if (!busy) {
      unawaited(_startAfterStop(turn));
    } else if (turn.now) {
      sendQueuedNow(turn.id);
    }
  }

  void _beginTurn(String id) {
    _turns.remove(id);
    // A plan the last turn put to the user: building, it is taken up; in
    // planning, what this message says changes it.
    final planId = _planId;
    if (planId != null) {
      emit(
        ItemUpserted(
          nextSeq,
          planId,
          PlanItem(
            path: '',
            round: 1,
            title: 'Plan',
            text: _planText,
            status: _modeId == 'plan'
                ? PlanStatus.sentBack
                : PlanStatus.approved,
          ),
        ),
      );
      _planId = null;
      _planText = null;
    }
    _turn = id;
    _serverTurn = null;
    _turnStarted = DateTime.now();
    if (!_turnsRun.contains(id)) _turnsRun.add(id);
    emit(TurnStarted(nextSeq, id));
  }

  Future<void> _run(KernelTurn turn) async {
    try {
      await _ensureStarted();
      // Picked on the other side of BaoCode since the thread began: the
      // server keeps it to the side it began on, so it goes on as a copy
      // of itself there (see [_forkToProvider]).
      if (_threadId case final threadId?
          when !_sameWay(_threadProvider, _modelId ?? '')) {
        await _forkToProvider(threadId);
      }
      await _ensureThread();
      if (_stoppedTurns.contains(turn.id) || _turn != turn.id) return;
      final result = await _request('turn/start', {
        'threadId': _threadId,
        'input': _input(turn),
        'model': _modelForServer,
        'approvalPolicy': _approvalPolicy,
        'sandboxPolicy': _sandboxPolicy,
        if (_effort case final effort?) 'effort': effort,
        if (_fastTier case final tier?)
          'serviceTierForTurn': tier
        else if (_fast == false)
          'serviceTierForTurn': 'default',
        if (_modeId == 'plan')
          'collaborationMode': {
            'mode': 'plan',
            'settings': {
              if (_modelForServer case final model?) 'model': model,
              if (_effort case final effort?) 'reasoning_effort': effort,
            },
          },
      });
      final serverTurn =
          ((result['turn'] as Map?)?.cast<String, Object?>())?['id'] as String?;
      if (_turn == turn.id) _serverTurn = serverTurn;
      if (serverTurn != null) {
        // The message this turn began with, to go back to, and to read it
        // back under when the conversation is resumed.
        _turnOfItem[turn.id] = serverTurn;
        _clientTurns[serverTurn] = turn.id;
      }
      // Stopped while starting, or already over: end it where it runs.
      if (_turn != turn.id) _interrupt(serverTurn);
    } on Object catch (error) {
      _failTurn(turn.id, error);
    }
  }

  Future<void> _ensureThread() async {
    if (_threadId != null) return;
    if (_sessionId != null) {
      await _resumeThread();
    } else {
      await _startThread();
    }
    final threadId = _threadId;
    final name = _pendingName;
    if (threadId != null && name != null) {
      _pendingName = null;
      unawaited(_name(threadId, name));
    }
  }

  List<Map<String, Object?>> _input(KernelTurn turn) => [
    for (final image in turn.images) ...[
      if (image.number case final number?)
        {'type': 'text', 'text': imageReference(number)},
      {
        'type': 'image',
        'url': 'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
      },
    ],
    for (final note in turn.notes) {'type': 'text', 'text': note},
    if (turn.text.isNotEmpty) {'type': 'text', 'text': _prompt(turn.text)},
  ];

  void _failTurn(String turnId, Object error) {
    if (_turn != turnId) return;
    emit(
      ItemUpserted(
        nextSeq,
        'turn-error:$turnId',
        NoticeItem(NoticeKind.error, _failureText(error)),
      ),
    );
    if (error is CodexUnavailable) {
      _setHealth(
        KernelHealth(
          KernelHealthStatus.failed,
          message: error.message,
          detail: error.detail,
        ),
      );
    }
    _endTurn(turnId, interrupted: true);
  }

  static String _failureText(Object error) {
    final text = '$error'.toLowerCase();
    if (text.contains('unauthorized') ||
        text.contains('not logged in') ||
        text.contains('login')) {
      return 'Codex is not logged in. Run `codex login` in a terminal, then '
          'try again.';
    }
    return 'Codex could not run this turn: $error';
  }

  /// The stop asked for and not yet answered: the next turn waits on it.
  Future<void>? _interrupting;

  void _interrupt([String? turn]) {
    final serverTurn = turn ?? _serverTurn;
    final threadId = _threadId;
    if (serverTurn == null || threadId == null || _transport == null) return;
    Future<void>? stopping;
    stopping =
        _request('turn/interrupt', {
          'threadId': threadId,
          'turnId': serverTurn,
        }).catchError((Object _) => <String, Object?>{}).whenComplete(() {
          if (identical(_interrupting, stopping)) _interrupting = null;
        });
    _interrupting = stopping;
    unawaited(stopping);
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _stoppedTurns.add(turn);
    _interrupt();
    _endTurn(turn, interrupted: true);
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (_asks.remove(requestId) case final ask?) {
      emit(InteractionResolved(nextSeq, requestId));
      _transport?.write({'id': ask.rpcId, 'result': ask.result(answer)});
      return;
    }
    if (!_approvals.containsKey(requestId)) return;
    final rpcId = _approvals.remove(requestId);
    emit(InteractionResolved(nextSeq, requestId));
    final decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    _transport?.write({
      'id': rpcId,
      'result': {'decision': decision},
    });
  }

  // --- Queue -----------------------------------------------------------------

  @override
  Future<bool> cancelQueued(String turnId) async {
    final at = _queue.indexOf(turnId);
    if (at < 0) return false;
    _queue.removeAt(at);
    _turns.remove(turnId);
    if (_nowNext == turnId) _nowNext = null;
    emit(ItemRemoved(nextSeq, turnId));
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    if (!_queue.contains(turnId)) return;
    final running = _turn;
    if (running == null) {
      _queue.remove(turnId);
      _take(turnId);
      return;
    }
    _nowNext = turnId;
    // The turn running ends when the server says it has stopped: one
    // started before that is turned down.
    _stoppedTurns.add(running);
    _interrupt();
    // A server that does not say it stopped would hold the queued message.
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_nowNext == turnId && _turn == running) {
        _endTurn(running, interrupted: true);
      }
    });
  }

  @override
  void moveQueued(String turnId, int index) {
    final at = _queue.indexOf(turnId);
    if (at < 0) return;
    _queue.removeAt(at);
    _queue.insert(index.clamp(0, _queue.length), turnId);
  }

  void _takeQueued() {
    if (_turn != null || _queue.isEmpty) return;
    final id = switch (_nowNext) {
      final wanted? when _queue.contains(wanted) => wanted,
      _ => _queue.first,
    };
    _nowNext = null;
    _queue.remove(id);
    _take(id);
  }

  void _take(String id) {
    final turn = _turns[id];
    if (turn == null) return;
    _beginTurn(id);
    // It waited its turn; now it is in the conversation.
    emit(
      ItemUpserted(
        nextSeq,
        id,
        UserMessageItem(
          text: turn.text,
          images: turn.images,
          sentAt: DateTime.now(),
        ),
      ),
    );
    unawaited(_startAfterStop(turn));
  }

  /// Runs [turn] once the turn before has been stopped where it ran: the
  /// server turns down one started while another is going.
  Future<void> _startAfterStop(KernelTurn turn) async {
    final stopping = _interrupting;
    if (stopping != null) await stopping;
    if (_turn != turn.id) return;
    await _run(turn);
  }

  @override
  void startBuilding() {
    if (_modeId != 'plan') return;
    mode.select('agent');
  }

  /// A name given before its thread began, kept for it.
  String? _pendingName;

  @override
  void rename(String title) {
    final threadId = _threadId;
    if (threadId == null) {
      _pendingName = title;
      return;
    }
    unawaited(_name(threadId, title));
  }

  Future<void> _name(String threadId, String title) async {
    await _request('thread/name/set', {
      'threadId': threadId,
      'name': title,
    }).catchError((Object _) => <String, Object?>{});
  }

  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    final threadId = _threadId;
    final turnId = _turnOfItem[itemId];
    if (threadId == null || turnId == null) return false;
    try {
      await _ensureStarted();
      await _request('thread/revert', {
        'threadId': threadId,
        'beforeTurnId': turnId,
      });
      emit(Rewound(nextSeq, itemId: itemId));
      return true;
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'rewind-error',
          NoticeItem(NoticeKind.error, 'Could not go back: $error'),
        ),
      );
      return false;
    }
  }

  @override
  Future<SessionRecord?> fork({String? before, required String title}) async {
    final threadId = _threadId;
    if (threadId == null) return null;
    try {
      await _ensureStarted();
      final beforeTurn = before == null ? null : _turnOfItem[before];
      final result = await _request('thread/fork', {
        'threadId': threadId,
        if (beforeTurn != null) 'beforeTurnId': beforeTurn,
      });
      final thread = (result['thread'] as Map?)?.cast<String, Object?>();
      final id = thread?['id'] as String?;
      if (id == null) return null;
      await _name(id, title);
      return SessionRecord(
        id: id,
        title: title,
        updatedAt: DateTime.now(),
        cwd: _context.cwd ?? _context.resume?.cwd ?? '',
        path: thread?['path'] as String?,
      );
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'fork-error',
          NoticeItem(NoticeKind.error, 'Could not copy this chat: $error'),
        ),
      );
      return null;
    }
  }

  @override
  Future<void> refreshUsage() async {
    try {
      await _ensureStarted();
      final result = await _request('account/rateLimits/read');
      _applyLimits(result['rateLimits']);
    } on Object {
      // The limits stay as last reported.
    }
  }

  // --- Earlier history -------------------------------------------------------

  @override
  Future<void> loadEarlier() {
    if (_turnsCursor == null || _disposed) return Future.value();
    return _earlierLoad ??= _loadTurnsPage(initial: false)
        .catchError((Object error) {
          emit(
            ItemUpserted(
              nextSeq,
              'history-error',
              NoticeItem(NoticeKind.error, 'Could not read earlier: $error'),
            ),
          );
        })
        .whenComplete(() {
          _earlierLoad = null;
          if (!_disposed) emitInfoChanged();
        });
  }

  Future<void> _loadTurnsPage({required bool initial}) async {
    final threadId = _threadId;
    if (threadId == null) return;
    final result = await _request('thread/turns/list', {
      'threadId': threadId,
      'limit': 30,
      'itemsView': 'full',
      'sortDirection': 'desc',
      if (!initial)
        if (_turnsCursor case final cursor?) 'cursor': cursor,
    });
    final next = result['nextCursor'] as String?;
    _turnsCursor = next == null || next.isEmpty ? null : next;
    // One page is newest first; the conversation goes oldest first.
    final turns = [
      for (final raw in result['data'] as List? ?? const [])
        if (raw is Map) raw.cast<String, Object?>(),
    ].reversed.toList();
    if (initial) {
      await _replay(turns);
    } else {
      final items = _itemsOf(turns);
      if (items.isNotEmpty) emit(HistoryPrepended(nextSeq, items));
    }
  }

  // --- Files put back --------------------------------------------------------

  @override
  void revertChanges({required String sinceTurn}) {
    unawaited(_revertChanges(sinceTurn));
  }

  Future<void> _revertChanges(String sinceTurn) async {
    final at = _turnsRun.indexOf(sinceTurn);
    if (at < 0) return;
    final root = _projectPath;
    if (root == null || root.isEmpty) return;
    final paths = _host.paths;
    final files = _host.files(root);
    String pathOf(String path) =>
        paths.isAbsolute(path) ? path : paths.join(root, path);
    var failed = 0;
    for (final turn in _turnsRun.sublist(at).reversed) {
      final edits = _editsByTurn[turn] ?? const <_EditedFile>[];
      for (final edit in edits.reversed) {
        final before = pathOf(edit.path);
        final after = pathOf(edit.moveTo ?? edit.path);
        try {
          switch (edit.kind) {
            case 'add':
              await files.delete(after);
            case 'delete':
              await files.write(before, edit.original);
            default:
              final now = await files.read(after);
              final restored = unpatch(now, edit.diff);
              if (restored == null) {
                failed++;
                continue;
              }
              if (after != before) await files.delete(after);
              await files.write(
                before,
                restored,
                expectedText: after == before ? now : null,
              );
          }
        } on Object {
          failed++;
        }
      }
    }
    emit(ChangesReverted(nextSeq));
    if (failed > 0) {
      emit(
        ItemUpserted(
          nextSeq,
          'revert-error',
          NoticeItem(
            NoticeKind.error,
            'Some changes could not be undone: $failed',
          ),
        ),
      );
    }
  }

  // --- MCP servers -------------------------------------------------------------

  @override
  void refreshMcpServers() => unawaited(_refreshMcpServers());

  Future<void> _refreshMcpServers() async {
    if (_disposed) return;
    try {
      await _ensureStarted();
      final result = await _request('mcpServerStatus/list', {
        'detail': 'toolsAndAuthOnly',
        if (_threadId case final thread?) 'threadId': thread,
      });
      _servers = [
        for (final raw in result['data'] as List? ?? const [])
          if (raw is Map) _mcpServer(raw.cast<String, Object?>()),
      ];
      emitInfoChanged();
    } on Object {
      // What was last reported stands.
    }
  }

  @override
  void setMcpServerEnabled(String name, bool enabled) {
    _setServerStatus(
      name,
      enabled ? McpServerStatus.pending : McpServerStatus.disabled,
    );
    unawaited(() async {
      try {
        await _ensureStarted();
        await _request('config/value/write', {
          'keyPath': 'mcp_servers.$name.enabled',
          'mergeStrategy': 'upsert',
          'value': enabled,
        });
        await _request('config/mcpServer/reload', null);
      } on Object {
        // Reported below as it stands.
      }
      await _refreshMcpServers();
    }());
  }

  @override
  void reconnectMcpServer(String name) {
    _setServerStatus(name, McpServerStatus.pending);
    unawaited(() async {
      try {
        await _ensureStarted();
        await _request('config/mcpServer/reload', null);
      } on Object {
        // Reported below as it stands.
      }
      await _refreshMcpServers();
    }());
  }

  @override
  Future<Uri?> authenticateMcpServer(String name) async {
    try {
      await _ensureStarted();
      final result = await _request('mcpServer/oauth/login', {
        'name': name,
        if (_threadId case final thread?) 'threadId': thread,
      });
      final url = Uri.tryParse('${result['authorizationUrl'] ?? ''}');
      return url != null && url.hasScheme ? url : null;
    } on Object {
      return null;
    }
  }

  /// Shows [name] as [status] until the server says where it stands.
  void _setServerStatus(String name, McpServerStatus status) {
    final servers = _servers;
    if (servers == null) return;
    _servers = [
      for (final server in servers)
        server.name == name
            ? McpServer(
                name: server.name,
                status: status,
                error: server.error,
                scope: server.scope,
                version: server.version,
                tools: server.tools,
              )
            : server,
    ];
    emitInfoChanged();
  }

  static McpServer _mcpServer(Map<String, Object?> raw) {
    final runtime = raw['runtimeStatus'] as String?;
    final auth = raw['authStatus'] as String?;
    final info = (raw['serverInfo'] as Map?)?.cast<String, Object?>();
    final tools = raw['tools'];
    return McpServer(
      name: raw['name'] as String? ?? 'MCP',
      status: switch (runtime) {
        'connected' => McpServerStatus.connected,
        'failed' || 'cancelled' => McpServerStatus.failed,
        'disabled' => McpServerStatus.disabled,
        'authenticationRequired' => McpServerStatus.needsAuth,
        'notStarted' || 'starting' =>
          auth == 'notLoggedIn'
              ? McpServerStatus.needsAuth
              : McpServerStatus.pending,
        _ =>
          auth == 'notLoggedIn'
              ? McpServerStatus.needsAuth
              : McpServerStatus.pending,
      },
      error: raw['toolsError'] as String?,
      version: info?['version'] as String?,
      tools: [
        if (tools is Map)
          for (final name in tools.keys) '$name',
      ],
    );
  }

  // --- Background tasks --------------------------------------------------------

  @override
  void stopTask(String taskId) {
    final threadId = _threadId;
    if (threadId == null) return;
    _tasks = [
      for (final task in _tasks)
        task.id == taskId ? task.copyWith(status: CommandStatus.failed) : task,
    ];
    emit(TasksReported(nextSeq, _tasks));
    unawaited(() async {
      try {
        await _request('thread/backgroundTerminals/terminate', {
          'threadId': threadId,
          'processId': taskId,
        });
      } on Object {
        // Listed again below, as it stands.
      }
      await _refreshTasks();
    }());
  }

  /// A running command is already in the background for the server: there
  /// is nothing to move.
  @override
  void moveToBackground(String toolUseId) {}

  Future<void> _refreshTasks() async {
    final threadId = _threadId;
    if (threadId == null || _transport == null || _disposed) return;
    try {
      final result = await _request('thread/backgroundTerminals/list', {
        'threadId': threadId,
      });
      final now = DateTime.now();
      _tasks = [
        for (final raw in result['data'] as List? ?? const [])
          if (raw is Map)
            KernelTask(
              id: '${raw['processId']}',
              description: raw['command'] as String? ?? 'Command',
              kind: KernelTaskKind.command,
              status: CommandStatus.running,
              startedAt: now,
              toolUseId: raw['itemId'] as String?,
            ),
      ];
      if (!_disposed) emit(TasksReported(nextSeq, _tasks));
    } on Object {
      // What was last reported stands.
    }
  }

  // --- What comes next -------------------------------------------------------

  Future<void> _askForSuggestion(String sourceTurnId) async {
    final threadId = _threadId;
    if (threadId == null || _disposed || !PromptSuggestions.current()) return;
    try {
      await _request('thread/prediction/request', {
        'threadId': threadId,
        'sourceTurnId': sourceTurnId,
      });
    } on Object {
      // Servers without predictions simply offer none.
    }
  }

  // --- Files by name ---------------------------------------------------------

  @override
  Future<List<FileSuggestion>> suggestFiles(String query) async {
    if (query.trim().isEmpty) return const [];
    final root = _projectPath;
    if (root == null) return const [];
    try {
      await _ensureStarted();
      final result = await _request('fuzzyFileSearch', {
        'query': query,
        'roots': [root],
      });
      final paths = _host.paths;
      return [
        for (final raw in result['files'] as List? ?? const [])
          if (raw is Map && raw['path'] is String)
            FileSuggestion(
              _suggestedPath(
                paths,
                raw['path'] as String,
                raw['root'] as String? ?? root,
                (raw['match_type'] ?? raw['matchType']) == 'directory',
              ),
            ),
      ];
    } on Object {
      return const [];
    }
  }

  static String _suggestedPath(
    p.Context paths,
    String path,
    String root,
    bool directory,
  ) {
    var out = path;
    if (paths.isWithin(root, path)) out = paths.relative(path, from: root);
    // As mentions are written, whatever the host's separator.
    out = paths.normalize(out).replaceAll(r'\', '/');
    return directory && !out.endsWith('/') ? '$out/' : out;
  }

  // --- Receiving -------------------------------------------------------------

  void _receive(Map<String, Object?> message, CodexTransport from) {
    if (_disposed || !identical(_transport, from)) return;
    if (CodexExit.isExit(message)) {
      _transportGone(from);
      return;
    }
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      final completer = _responses.remove(message['id']);
      if (completer == null) return;
      if (message['error'] case final Map error) {
        final code = error['code'];
        completer.completeError(
          CodexRpcError(
            code is int ? code : -1,
            error['message'] as String? ?? 'Codex request failed',
          ),
        );
      } else {
        completer.complete(
          (message['result'] as Map?)?.cast<String, Object?>() ?? const {},
        );
      }
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    _notification(method, params ?? const {});
  }

  void _notification(String method, Map<String, Object?> params) {
    switch (method) {
      case 'turn/started':
        final turn = (params['turn'] as Map?)?.cast<String, Object?>();
        _serverTurn = turn?['id'] as String?;
      case 'turn/completed':
        if (_turn case final ours?) {
          final turn = (params['turn'] as Map?)?.cast<String, Object?>();
          if (turn == null || turn['id'] != _serverTurn) return;
          final source = _serverTurn;
          _serverTurn = null;
          final status = turn['status'];
          if (status == 'failed') {
            _turnError(turn['error']);
          } else if (status == 'completed') {
            _usageLimited = false;
            _limitResetsAt = null;
          }
          _endTurn(ours, interrupted: status != 'completed');
          if (status == 'completed' && source != null) {
            unawaited(_askForSuggestion(source));
          }
          unawaited(_refreshTasks());
        }
      case 'turn/plan/updated':
        _plan(params);
      case 'item/started':
        _itemStarted(
          (params['item'] as Map?)?.cast<String, Object?>(),
          params['turnId'] as String?,
        );
      case 'item/completed':
        _itemCompleted(
          (params['item'] as Map?)?.cast<String, Object?>(),
          params['turnId'] as String?,
        );
      case 'item/agentMessage/delta':
        final id = params['itemId'] as String?;
        final delta = params['delta'] as String?;
        if (id == null || delta == null) return;
        final offset = _textLength[id];
        if (offset == null) {
          // Said without starting first.
          _textLength[id] = delta.length;
          emit(
            ItemUpserted(
              nextSeq,
              id,
              AssistantTextItem(delta),
              streaming: true,
            ),
          );
          return;
        }
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'item/reasoning/summaryTextDelta':
        _reasoningDelta(params);
      case 'item/reasoning/summaryPartAdded':
        final id = params['itemId'] as String?;
        final buffer = id == null ? null : _reasoning[id];
        if (id != null && buffer != null && buffer.isNotEmpty) {
          final offset = buffer.length;
          buffer.write('\n\n');
          emit(TextDelta(nextSeq, id, offset, '\n\n', tokens: buffer.length));
        }
      case 'item/commandExecution/outputDelta':
        _commandDelta(params);
      case 'item/fileChange/patchUpdated':
        _filePatchUpdated(params);
      case 'item/mcpToolCall/progress':
        final id = params['itemId'] as String?;
        final message = params['message'] as String?;
        final item = id == null ? null : _mcpCalls[id];
        if (id != null && message != null && item != null) {
          final chat = _toolItem({...item, 'progress': message}, done: false);
          if (chat != null) emit(ItemUpserted(nextSeq, id, chat));
        }
      case 'thread/tokenUsage/updated':
        _tokenUsage(params);
      case 'account/rateLimits/updated':
        _applyLimits(params['rateLimits']);
      case 'thread/name/updated':
        final name = (params['threadName'] ?? params['name']) as String?;
        if (name != null && name.isNotEmpty) {
          emit(SessionRenamed(nextSeq, name));
        }
      case 'thread/compacted':
        emit(
          ItemUpserted(
            nextSeq,
            'compact:${nextSeq}',
            const NoticeItem(
              NoticeKind.compaction,
              'The conversation was summarized',
            ),
          ),
        );
      case 'mcpServer/startupStatus/updated':
        _mcpStatus(params);
      case 'mcpServer/oauthLogin/completed':
        unawaited(_refreshMcpServers());
      case 'thread/prediction/updated':
        _prediction(params);
      case 'serverRequest/resolved':
        _resolveRequest(params['requestId']);
    }
  }

  /// A server from the MCP list, as it now starts.
  void _mcpStatus(Map<String, Object?> params) {
    final name = params['name'] as String?;
    final servers = _servers;
    if (name == null || servers == null) return;
    final status = switch (params['status']) {
      'ready' => McpServerStatus.connected,
      'failed' =>
        params['failureReason'] == 'reauthenticationRequired'
            ? McpServerStatus.needsAuth
            : McpServerStatus.failed,
      'cancelled' => McpServerStatus.disabled,
      _ => McpServerStatus.pending,
    };
    _servers = [
      for (final server in servers)
        server.name == name
            ? McpServer(
                name: server.name,
                status: status,
                error: params['error'] as String? ?? server.error,
                scope: server.scope,
                version: server.version,
                tools: server.tools,
              )
            : server,
    ];
    emitInfoChanged();
  }

  void _prediction(Map<String, Object?> params) {
    // Another thread's, or one asked before this turn began: not what
    // would come next here.
    final threadId = params['threadId'] as String?;
    if (threadId != null && _threadId != null && threadId != _threadId) {
      return;
    }
    if (_turn != null) return;
    final result = (params['result'] as Map?)?.cast<String, Object?>();
    if (result == null || result['type'] != 'completed') return;
    final text = (result['text'] as String?)?.trim();
    if (text == null || text.isEmpty || text == _suggestion) return;
    _suggestion = text;
    emitInfoChanged();
  }

  /// The server itself settled a request it asked: taken off the user.
  void _resolveRequest(Object? requestId) {
    if (requestId == null) return;
    for (final entry in [..._approvals.entries]) {
      if ('${entry.value}' != '$requestId') continue;
      _approvals.remove(entry.key);
      emit(InteractionResolved(nextSeq, entry.key));
    }
    _asks.removeWhere((id, ask) {
      if ('${ask.rpcId}' != '$requestId') return false;
      emit(InteractionResolved(nextSeq, id));
      return true;
    });
  }

  void _reasoningDelta(Map<String, Object?> params) {
    final id = params['itemId'] as String?;
    final delta = params['delta'] as String?;
    if (id == null || delta == null) return;
    final buffer = _reasoning[id] ?? _startThought(id);
    final offset = buffer.length;
    buffer.write(delta);
    emit(TextDelta(nextSeq, id, offset, delta, tokens: buffer.length));
  }

  /// A thought said without starting first: its row, and its text to come.
  StringBuffer _startThought(String id) {
    final buffer = StringBuffer();
    _reasoning[id] = buffer;
    _reasoningClock[id] = Stopwatch()..start();
    emit(
      ItemUpserted(
        nextSeq,
        id,
        ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now()),
        streaming: true,
      ),
    );
    return buffer;
  }

  void _commandDelta(Map<String, Object?> params) {
    final id = params['itemId'] as String?;
    final delta = params['delta'] as String?;
    if (id == null || delta == null) return;
    final item = _commands[id];
    if (item == null) return;
    final output = (_commandOutput[id] ??= StringBuffer())..write(delta);
    emit(
      ItemUpserted(
        nextSeq,
        id,
        _commandItem({
          ...item,
          'aggregatedOutput': output.toString(),
        }, done: false),
      ),
    );
  }

  void _filePatchUpdated(Map<String, Object?> params) {
    final id = params['itemId'] as String?;
    final changes = params['changes'] as List?;
    if (id == null || changes == null) return;
    // Only the card goes up as it changes; the change is recorded once the
    // file is done, so a repeated patch adds nothing new.
    _fileChanges(id, changes, record: false);
  }

  void _tokenUsage(Map<String, Object?> params) {
    final usage = (params['tokenUsage'] as Map?)?.cast<String, Object?>();
    if (usage == null) return;
    final window =
        (usage['modelContextWindow'] as num?)?.toInt() ?? _contextWindow;
    final last = (usage['last'] as Map?)?.cast<String, Object?>();
    final used = (last?['totalTokens'] as num?)?.toInt();
    if (used == null) return;
    _contextWindow = window;
    final total = (usage['total'] as Map?)?.cast<String, Object?>();
    _cache = PromptCache(
      last: _cacheTokens(last),
      conversation: _cacheTokens(total ?? last),
    );
    emit(UsageReported(nextSeq, ContextUsage(window: window, used: used)));
    emit(StatsReported(nextSeq, UsageStats(limits: _limits, cache: _cache)));
  }

  static CacheTokens _cacheTokens(Map<String, Object?>? tokens) {
    final input = (tokens?['inputTokens'] as num?)?.toInt() ?? 0;
    final cached = (tokens?['cachedInputTokens'] as num?)?.toInt() ?? 0;
    final written = (tokens?['cacheWriteInputTokens'] as num?)?.toInt() ?? 0;
    return CacheTokens(
      read: cached,
      written: written,
      uncached: math.max(0, input - cached - written).toInt(),
    );
  }

  void _applyLimits(Object? raw) {
    if (raw is! Map) return;
    final windows = <RateLimitWindow>[];
    for (final (label, key) in const [
      ('5h', 'primary'),
      ('Weekly', 'secondary'),
    ]) {
      final window = (raw[key] as Map?)?.cast<String, Object?>();
      if (window == null) continue;
      final percent = window['usedPercent'];
      if (percent is! num) continue;
      windows.add(
        RateLimitWindow(
          label,
          percent / 100,
          resetsAt: _time(window['resetsAt']),
        ),
      );
    }
    if (windows.isEmpty) return;
    _limits = windows;
    final reached = raw['rateLimitReachedType'];
    if (reached != null) {
      _usageLimited = true;
      _limitResetsAt = _earliestReset(windows);
    }
    emit(StatsReported(nextSeq, UsageStats(limits: _limits, cache: _cache)));
  }

  void _turnError(Object? raw) {
    final error = raw is Map ? raw.cast<String, Object?>() : null;
    final info = error?['codexErrorInfo'];
    final message =
        error?['message'] as String? ??
        (raw is String ? raw : 'The turn failed');
    final limited =
        info == 'usageLimitExceeded' ||
        info == 'rateLimitExceeded' ||
        message.toLowerCase().contains('usage limit') ||
        message.toLowerCase().contains('rate limit');
    if (limited) {
      _usageLimited = true;
      _limitResetsAt = _earliestReset(_limits);
    }
    emit(
      ItemUpserted(
        nextSeq,
        'turn-error:${_turn ?? nextSeq}',
        NoticeItem(NoticeKind.error, message),
      ),
    );
  }

  static DateTime? _earliestReset(List<RateLimitWindow> windows) {
    final now = DateTime.now();
    DateTime? earliest;
    for (final window in windows) {
      final at = window.resetsAt;
      if (at == null || !at.isAfter(now)) continue;
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }
    return earliest ?? windows.firstOrNull?.resetsAt;
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    switch (method) {
      case 'item/commandExecution/requestApproval':
        _approval(
          rpcId,
          'Run command',
          'commandExecution',
          params,
          preview: CommandPreview(_text(params['command'])),
        );
      case 'item/fileChange/requestApproval':
        _approval(rpcId, 'Apply changes', 'fileChange', params);
      case 'item/permissions/requestApproval':
        _permissionRequest(rpcId, params);
      case 'item/tool/requestUserInput':
        _userInput(rpcId, params);
      case 'mcpServer/elicitation/request':
        _elicitation(rpcId, params);
      default:
        // Not one this client knows: turned down, rather than left waiting.
        _transport?.write({
          'id': rpcId,
          'error': {'code': -32601, 'message': 'Not supported by BaoCode'},
        });
    }
  }

  void _approval(
    Object? rpcId,
    String title,
    String toolName,
    Map<String, Object?> params, {
    ApprovalPreview? preview,
  }) {
    final id = 'approval:$rpcId';
    _approvals[id] = rpcId;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: title,
          toolName: toolName,
          reason: params['reason'] is String
              ? params['reason'] as String
              : null,
          preview: preview,
          alwaysAllowLabel: 'Approve for this session',
        ),
      ),
    );
  }

  /// More than the sandbox lets it have (a folder, the network): granted
  /// for the turn, or for the session.
  void _permissionRequest(Object? rpcId, Map<String, Object?> params) {
    final requested = params['permissions'];
    final id = 'ask:$rpcId';
    _asks[id] = _Ask(rpcId, (answer) {
      final decision = answer is ApprovalAnswer ? answer.decision : null;
      final allow = decision != null && decision != ApprovalDecision.deny;
      return {
        'permissions': allow && requested is Map
            ? requested.cast<String, Object?>()
            : const <String, Object?>{},
        if (allow)
          'scope': decision == ApprovalDecision.allowAlways
              ? 'session'
              : 'turn',
      };
    });
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: 'Grant extra permissions',
          toolName: 'permissions',
          reason: params['reason'] as String?,
          preview: TextPreview(
            requested is Map
                ? JsonEncoder.withIndent('  ').convert(requested)
                : '',
          ),
          alwaysAllowLabel: 'Allow for this session',
        ),
      ),
    );
  }

  void _userInput(Object? rpcId, Map<String, Object?> params) {
    final raw = [
      for (final question in params['questions'] as List? ?? const [])
        if (question is Map) question.cast<String, Object?>(),
    ];
    final id = 'ask:$rpcId';
    _asks[id] = _Ask(rpcId, (answer) {
      final picks = answer is QuestionAnswer
          ? answer.picks
          : const <List<String>>[];
      final answers = <String, Object?>{};
      for (final (index, question) in raw.indexed) {
        final questionId = question['id'] as String?;
        if (questionId == null) continue;
        final picked = index < picks.length ? picks[index] : const <String>[];
        if (picked.isEmpty && answer is QuestionAnswer && answer.skipped) {
          continue;
        }
        answers[questionId] = {'answers': picked};
      }
      return {'answers': answers};
    });
    emit(
      InteractionRequested(
        nextSeq,
        QuestionRequest(
          id: id,
          title: params['title'] as String? ?? 'The agent asks',
          questions: [
            for (final question in raw)
              Question(
                prompt: question['question'] as String? ?? '',
                header: question['header'] as String? ?? '',
                allowMultiple: false,
                allowOther:
                    question['isOther'] == true || question['options'] == null,
                options: [
                  for (final option in question['options'] as List? ?? const [])
                    if (option is Map)
                      QuestionOption(
                        option['label'] as String? ?? '',
                        description: option['description'] as String? ?? '',
                      ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _elicitation(Object? rpcId, Map<String, Object?> params) {
    final server = params['serverName'] as String? ?? 'MCP';
    final message = params['message'] as String? ?? '';
    final mode = params['mode'] as String?;
    final id = 'ask:$rpcId';
    // A form this app can show, a link, or (a device check, say) nothing
    // it can: that one is turned down rather than shown as nothing.
    if (mode != null &&
        mode != 'url' &&
        mode != 'form' &&
        mode != 'openai/form' &&
        mode != 'openaiForm') {
      _transport?.write({
        'id': rpcId,
        'result': {'action': 'decline'},
      });
      return;
    }
    if (mode == 'url') {
      final url = params['url'] as String? ?? '';
      _asks[id] = _Ask(rpcId, (answer) {
        if (answer is QuestionAnswer && answer.skipped) {
          return {'action': 'cancel'};
        }
        final allow =
            answer is ApprovalAnswer &&
            answer.decision != ApprovalDecision.deny;
        if (allow && url.isNotEmpty) unawaited(openExternal(url));
        return {'action': allow ? 'accept' : 'decline'};
      });
      emit(
        InteractionRequested(
          nextSeq,
          ApprovalRequest(
            id: id,
            title: '$server wants you to open a link',
            toolName: 'mcp__$server',
            reason: message.isEmpty ? null : message,
            preview: TextPreview(url),
          ),
        ),
      );
      return;
    }
    final fields = elicitationFields(params['requestedSchema']);
    _asks[id] = _Ask(
      rpcId,
      (answer) => elicitationResult(
        fields,
        answer is QuestionAnswer
            ? answer
            : const QuestionAnswer([], skipped: true),
      ),
    );
    emit(
      InteractionRequested(
        nextSeq,
        QuestionRequest(
          id: id,
          title: '$server asks for input',
          questions: elicitationQuestions(message, fields),
        ),
      ),
    );
  }

  // --- Items -----------------------------------------------------------------

  void _itemStarted(Map<String, Object?>? item, String? turnId) {
    if (item == null) return;
    final id = item['id'] as String?;
    if (id == null) return;
    if (turnId != null) _turnOfItem[id] = turnId;
    switch (item['type']) {
      case 'userMessage':
        // Sent by this app already (the turn's own id).
        return;
      case 'reasoning':
        _startThought(id);
      case 'agentMessage':
        _textLength[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        _commandOutput[id] = StringBuffer();
        emit(ItemUpserted(nextSeq, id, _commandItem(item, done: false)));
      case 'fileChange':
        _fileChanges(id, item['changes'] as List? ?? const [], record: false);
      case 'mcpToolCall':
        _mcpCalls[id] = item;
        final chat = _toolItem(item, done: false);
        if (chat != null) emit(ItemUpserted(nextSeq, id, chat));
      case 'webSearch':
      case 'imageView':
      case 'contextCompaction':
      case 'collabAgentToolCall':
      case 'enteredReviewMode':
      case 'exitedReviewMode':
        final chat = _toolItem(item, done: false);
        if (chat != null) emit(ItemUpserted(nextSeq, id, chat));
    }
  }

  void _itemCompleted(Map<String, Object?>? item, String? turnId) {
    if (item == null) return;
    final id = item['id'] as String?;
    if (id == null) return;
    if (turnId != null) _turnOfItem[id] = turnId;
    switch (item['type']) {
      case 'userMessage':
        // Sent by this app already, under the turn's own id.
        return;
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        final text =
            buffer?.toString() ??
            (item['summary'] as List<Object?>? ?? const []).join('\n\n');
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math
                  .max(1, ((clock?.elapsedMilliseconds ?? 0) / 1000).round())
                  .toInt(),
            ),
          ),
        );
      case 'agentMessage':
        _textLength.remove(id);
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(item['text'] as String? ?? ''),
          ),
        );
      case 'commandExecution':
        final output = _commandOutput.remove(id)?.toString();
        final completed = {
          ...item,
          if (output != null && output.isNotEmpty)
            'aggregatedOutput': item['aggregatedOutput'] ?? output,
        };
        _commands.remove(id);
        emit(ItemUpserted(nextSeq, id, _commandItem(completed, done: true)));
        emit(FilesMayHaveChanged(nextSeq));
        _startedAt.remove(id);
      case 'fileChange':
        _fileChanges(id, item['changes'] as List? ?? const []);
        emit(FilesMayHaveChanged(nextSeq));
      default:
        _mcpCalls.remove(id);
        final chat = _toolItem(item, done: true);
        if (chat != null) {
          emit(ItemCompleted(nextSeq, id, item: chat));
        }
    }
  }

  static UserMessageItem _userItem(Map<String, Object?> item) {
    final content = item['content'] as List? ?? const [];
    final parts = <String>[];
    final images = <ImageAttachment>[];
    for (final raw in content) {
      if (raw is! Map) continue;
      if (raw['type'] == 'text' && raw['text'] is String) {
        parts.add(raw['text'] as String);
      } else if (raw['type'] == 'image') {
        final image = _historyImage(raw['url'] ?? raw['image_url']);
        if (image != null) images.add(image);
      }
    }
    return UserMessageItem(text: parts.join('\n'), images: images);
  }

  /// A picture an earlier message carried, as a data URL.
  static ImageAttachment? _historyImage(Object? url) {
    if (url is! String || !url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final header = url.substring(5, comma);
    final mediaType = header.split(';').first;
    try {
      return ImageAttachment(
        bytes: base64Decode(url.substring(comma + 1)),
        mediaType: mediaType,
      );
    } on FormatException {
      return null;
    }
  }

  /// A kept conversation, as it was: its items, without turn timings.
  Future<void> _replay(List? turns) async {
    _loadingHistory = true;
    emitInfoChanged();
    try {
      final items = _itemsOf([
        for (final raw in turns ?? const [])
          if (raw is Map) raw.cast<String, Object?>(),
      ]);
      for (final (id, item) in items) {
        emit(ItemUpserted(nextSeq, id, item));
      }
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq,
          'history-error',
          NoticeItem(NoticeKind.error, 'Could not read this session: $error'),
        ),
      );
    } finally {
      _loadingHistory = false;
      if (!_disposed) emitInfoChanged();
    }
  }

  /// The conversation [turns] hold, oldest first, as it shows read back.
  ///
  /// Changes themselves are left to when they were made: only their cards
  /// are shown, and nothing is kept to put back.
  List<(String, ChatItem)> _itemsOf(List turns) {
    final items = <(String, ChatItem)>[];
    for (final turn in turns) {
      final turnId = turn['id'] as String?;
      for (final rawItem in turn['items'] as List? ?? const []) {
        if (rawItem is! Map) continue;
        final item = rawItem.cast<String, Object?>();
        final id = item['id'] as String?;
        if (id == null) continue;
        if (turnId != null) _turnOfItem[id] = turnId;
        if (item['type'] == 'fileChange') {
          for (final (index, raw)
              in (item['changes'] as List? ?? const []).indexed) {
            if (raw is! Map) continue;
            items.add((
              '$id:$index',
              _diff(
                raw['path'] as String? ?? '',
                raw['diff'] as String? ?? '',
              ).item,
            ));
          }
          continue;
        }
        // A message this kernel sent is already in the conversation, as it
        // showed it (with its pictures); read back, it is left so.
        if (item['type'] == 'userMessage' &&
            turnId != null &&
            _clientTurns.containsKey(turnId)) {
          continue;
        }
        final chat = _historyItem(item);
        if (chat != null) items.add((id, chat));
      }
    }
    return items;
  }

  ChatItem? _historyItem(Map<String, Object?> item) {
    switch (item['type']) {
      case 'userMessage':
        return _userItem(item);
      case 'agentMessage':
        final text = item['text'] as String? ?? '';
        return text.isEmpty ? null : AssistantTextItem(text);
      case 'reasoning':
        final text = (item['summary'] as List? ?? const []).join('\n\n');
        return text.isEmpty
            ? null
            : ThinkingItem(text: text, tokens: text.length);
      case 'commandExecution':
        return _commandItem(item, done: true);
      default:
        return _toolItem(item, done: true);
    }
  }

  /// A command as the history shows it: reads and searches as tool rows,
  /// anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item, {required bool done}) {
    final actions = [
      for (final action in item['commandActions'] as List? ?? const [])
        if (action is Map) action.cast<String, Object?>(),
    ];
    final output =
        item['aggregatedOutput'] as String? ??
        _commandOutput[item['id']]?.toString();
    final completed =
        done || item['status'] == 'completed' || item['status'] == 'failed';
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = actions.first['path'] as String? ?? '';
      return ToolCallItem(
        kind: ToolKind.read,
        target: p.basename(path),
        path: path,
        status: completed ? ToolStatus.succeeded : ToolStatus.running,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String? ?? '',
        detail: completed ? '${matches.length} results' : null,
        results: matches,
        status: completed ? ToolStatus.succeeded : ToolStatus.running,
      );
    }
    return TerminalItem(
      command: _text(item['command']),
      output: output ?? '',
      status: !completed
          ? CommandStatus.running
          : item['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: _startedAt[item['id']],
    );
  }

  /// The other item kinds the protocol reports: MCP calls, web searches,
  /// images shown, and subagents.
  ChatItem? _toolItem(Map<String, Object?> item, {required bool done}) {
    switch (item['type']) {
      case 'mcpToolCall':
        final result = item['result'] is Map
            ? (item['result'] as Map).cast<String, Object?>()
            : null;
        final error = item['error'] is Map
            ? (item['error'] as Map).cast<String, Object?>()
            : null;
        return ToolCallItem(
          kind: ToolKind.mcp,
          target: '${item['server'] ?? 'MCP'}: ${item['tool'] ?? 'tool'}',
          label: item['server'] as String?,
          tool: item['tool'] as String?,
          status: switch (item['status']) {
            'failed' => ToolStatus.failed,
            'inProgress' => ToolStatus.running,
            _ => ToolStatus.succeeded,
          },
          input: item['arguments'] is Map
              ? (item['arguments'] as Map).cast<String, Object?>()
              : const {},
          output: _mcpOutput(result),
          detail: error?['message'] as String? ?? item['progress'] as String?,
        );
      case 'webSearch':
        final query = item['query'] as String? ?? '';
        final results = item['results'] as List?;
        return ToolCallItem(
          kind: ToolKind.web,
          target: query,
          detail: done && results != null ? '${results.length} results' : null,
          status: done ? ToolStatus.succeeded : ToolStatus.running,
        );
      case 'imageView':
        final path = item['path'] as String? ?? '';
        return ToolCallItem(
          kind: ToolKind.read,
          target: p.basename(path),
          path: path,
          status: ToolStatus.succeeded,
        );
      case 'contextCompaction':
        return const NoticeItem(
          NoticeKind.compaction,
          'The conversation was summarized',
        );
      case 'collabAgentToolCall':
        final tool = _label(item['tool']);
        return AgentItem(
          description: item['prompt'] as String? ?? tool ?? 'Agent',
          id: item['id'] as String?,
          agentType: tool,
          prompt: item['prompt'] as String?,
          model: item['model'] as String?,
          status: switch (item['status']) {
            'failed' || 'errored' => CommandStatus.failed,
            'completed' => CommandStatus.succeeded,
            'interrupted' => CommandStatus.failed,
            _ => CommandStatus.running,
          },
          startedAt: done ? null : DateTime.now(),
          background: true,
        );
      case 'enteredReviewMode':
        return NoticeItem(
          NoticeKind.info,
          'Review started: ${item['review'] ?? ''}',
        );
      case 'exitedReviewMode':
        return NoticeItem(
          NoticeKind.info,
          'Review ended: ${item['review'] ?? ''}',
        );
    }
    return null;
  }

  /// A command as the server gives it, one string or its words.
  static String _text(Object? raw) => raw is List
      ? raw.join(' ')
      : raw is String
      ? raw
      : '';

  /// A name the server gives as a string, or as an object with its type.
  static String? _label(Object? raw) => raw is String
      ? raw
      : raw is Map && raw['type'] is String
      ? raw['type'] as String
      : null;

  static String? _mcpOutput(Map<String, Object?>? result) {
    final content = result?['content'] as List?;
    if (content == null) return null;
    final texts = <String>[];
    for (final raw in content) {
      if (raw is Map && raw['type'] == 'text' && raw['text'] is String) {
        texts.add(raw['text'] as String);
      }
    }
    return texts.isEmpty ? null : texts.join('\n');
  }

  /// A unified diff as a diff card and a pending change.
  void _fileChanges(String itemId, List changes, {bool record = true}) {
    for (final (index, raw) in changes.indexed) {
      if (raw is! Map) continue;
      final path = raw['path'] as String? ?? '';
      final diff = raw['diff'] as String? ?? '';
      final rawKind = raw['kind'];
      final kind = rawKind is Map
          ? rawKind['type'] as String?
          : rawKind is String
          ? rawKind
          : null;
      final moveTo = rawKind is Map ? rawKind['move_path'] as String? : null;
      _fileChange(
        '$itemId:$index',
        path,
        diff,
        kind: kind,
        moveTo: moveTo,
        record: record,
      );
    }
  }

  void _fileChange(
    String id,
    String path,
    String diff, {
    String? kind,
    String? moveTo,
    bool record = true,
  }) {
    final change = _diff(path, diff);
    emit(ItemUpserted(nextSeq, id, change.item));
    if (!record) return;
    final original = switch (kind) {
      'add' => const OriginalText(null),
      'delete' => OriginalText(_oldText(diff)),
      _ => OriginalByPatch(diff),
    };
    // What was done this turn, kept to put the files back.
    if (_turn case final turn?) {
      (_editsByTurn[turn] ??= []).add(
        _EditedFile(
          path: path,
          diff: diff,
          kind: kind ?? 'update',
          moveTo: moveTo,
          original: original is OriginalText ? original.text ?? '' : '',
        ),
      );
    }
    emit(
      FileEdited(
        nextSeq,
        FileChange(
          path: path,
          added: change.added,
          removed: change.removed,
          kind: switch (kind) {
            'add' => FileChangeKind.added,
            'delete' => FileChangeKind.deleted,
            _ => FileChangeKind.modified,
          },
        ),
        turnId: _turn,
        original: original,
      ),
    );
  }

  /// The text a deleted file had: the old side of its diff, or the diff
  /// itself when the server gave the file as it was.
  static String _oldText(String diff) {
    if (!diff.contains('@@')) return diff;
    final lines = <String>[];
    for (final line in diff.split('\n')) {
      if (line.isEmpty ||
          line.startsWith('@@') ||
          line.startsWith('---') ||
          line.startsWith('+++') ||
          line.startsWith('+') ||
          line.startsWith('\\')) {
        continue;
      }
      lines.add(line.substring(1));
    }
    return lines.isEmpty ? '' : '${lines.join('\n')}\n';
  }

  static ({CodeDiffItem item, int added, int removed}) _diff(
    String path,
    String diff,
  ) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty || line.startsWith('\\')) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
          added++;
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
          removed++;
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    return (
      item: CodeDiffItem(
        fileName: p.basename(path),
        directory: p.dirname(path) == '.' ? '' : p.dirname(path),
        lines: lines,
      ),
      added: added,
      removed: removed,
    );
  }

  // --- Plan ------------------------------------------------------------------

  void _plan(Map<String, Object?> params) {
    final steps = params['plan'] as List? ?? const [];
    final explanation = params['explanation'] as String?;
    final lines = <String>[
      if (explanation != null && explanation.isNotEmpty) explanation,
      for (final raw in steps)
        if (raw is Map)
          '- [${switch (raw['status']) {
            'completed' => 'x',
            'inProgress' => '~',
            _ => ' ',
          }}] ${raw['step'] ?? ''}',
    ];
    final text = lines.join('\n');
    final id = 'plan:${params['turnId'] ?? nextSeq}';
    _planId = id;
    _planText = text;
    emit(
      ItemUpserted(
        nextSeq,
        id,
        PlanItem(
          path: '',
          round: 1,
          title: 'Plan',
          text: text,
          status: PlanStatus.drafting,
        ),
      ),
    );
  }

  void _endTurn(String turn, {required bool interrupted}) {
    // Ended once: a late word of the server about it changes nothing.
    if (_turn != turn) return;
    _turn = null;
    _serverTurn = null;
    final began = _turnStarted;
    _turnStarted = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id}, null);
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'}, null);
    }
    for (final id in [..._approvals.keys, ..._asks.keys]) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    _asks.clear();
    _mcpCalls.clear();
    final planId = _planId;
    // A plan this turn wrote: out of drafting, for the user to start.
    if (_modeId == 'plan' && planId != null) {
      emit(
        ItemUpserted(
          nextSeq,
          planId,
          PlanItem(
            path: '',
            round: 1,
            title: 'Plan',
            text: _planText,
            status: PlanStatus.awaiting,
          ),
        ),
      );
    }
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: began == null ? null : DateTime.now().difference(began),
      ),
    );
    _takeQueued();
  }

  static DateTime? _time(Object? raw) {
    if (raw is! num) return null;
    final value = raw.toInt();
    return value < 100000000000
        ? DateTime.fromMillisecondsSinceEpoch(value * 1000)
        : DateTime.fromMillisecondsSinceEpoch(value);
  }
}

class CodexRpcError implements Exception {
  const CodexRpcError(this.code, this.message);

  final int code;
  final String message;

  bool get unauthorized =>
      code == 401 ||
      message.toLowerCase().contains('unauthorized') ||
      message.toLowerCase().contains('not logged in');

  @override
  String toString() => message;
}

class _EffortSetting implements ModelSetting {
  _EffortSetting(this.kernel);

  final CodexKernel kernel;

  @override
  List<KernelOption> optionsFor(String model) {
    // One of BaoCode's: its provider says which it takes.
    if (kernel._providers.resolve(model) case (_, final info)) {
      return [
        for (final level in info.effortLevels)
          KernelOption(
            level,
            effortLabel(level),
            Icons.speed_rounded,
            switch (level) {
              'none' => 'No thinking',
              'low' => 'Fastest, least thinking',
              'medium' => 'Balanced',
              'high' => 'Thinks more',
              'xhigh' => 'Thinks a lot more',
              'max' => 'Most thinking',
              _ => '',
            },
          ),
      ];
    }
    return kernel._effortsByModel[model] ?? const [];
  }

  @override
  String? get selected => kernel._effort;

  @override
  String? selectedFor(String model) {
    if (kernel._providers.resolve(model) case (_, final info)) {
      final picked =
          kernel._pickedEfforts[model] ??
          (model == kernel._modelId ? kernel._effort : null);
      return info.effortLevels.contains(picked) ? picked : info.initialEffort;
    }
    return kernel._pickedEfforts[model] ??
        kernel._defaultEfforts[model] ??
        (model == kernel._modelId ? kernel._effort : null);
  }

  @override
  void select(String model, String id) {
    kernel._pickedEfforts[model] = id;
    if (model == kernel._modelId) kernel._effort = id;
    kernel.emitInfoChanged();
  }

  @override
  bool get toggle => false;
}

/// Fast mode: the model's first service tier besides the standard one.
class _FastSetting implements ModelSetting {
  _FastSetting(this.kernel);

  final CodexKernel kernel;

  /// Offered as one switch, like another kernel's fast mode: what it turns
  /// on is the model's first tier besides the standard one.
  @override
  List<KernelOption> optionsFor(String model) {
    // One of BaoCode's: fast is in its name, for the models that take it.
    if (kernel._providers.resolve(model) case (final provider, final info)) {
      if (!CodexKernel._offersFast(provider, info)) return const [];
      return const [KernelOption('fast', 'Fast', Icons.bolt_rounded, '')];
    }
    final tier = kernel._tiersByModel[model]?.firstOrNull;
    if (tier == null) return const [];
    return [
      KernelOption(
        'fast',
        'Fast',
        Icons.bolt_rounded,
        tier.description.isEmpty ? tier.label : tier.description,
      ),
    ];
  }

  @override
  String? get selected => kernel._custom != null
      ? (kernel._fast ? 'fast' : 'standard')
      : (kernel._fastTier == null ? 'standard' : 'fast');

  @override
  String? selectedFor(String model) {
    if (kernel._providers.resolve(model) case (final provider, final info)) {
      final picked =
          kernel._pickedFast[model] ??
          (model == kernel._modelId && kernel._fast);
      return picked && CodexKernel._offersFast(provider, info)
          ? 'fast'
          : 'standard';
    }
    final picked =
        kernel._pickedFast[model] ??
        (model == kernel._modelId && kernel._fastTier != null);
    return picked ? 'fast' : 'standard';
  }

  @override
  void select(String model, String id) {
    if (id != 'fast') return;
    if (kernel._providers.resolve(model) case (final provider, final info)) {
      if (!CodexKernel._offersFast(provider, info)) return;
      final fast = model == kernel._modelId
          ? !kernel._fast
          : kernel._pickedFast[model] != true;
      kernel._pickedFast[model] = fast;
      if (model == kernel._modelId) {
        kernel._fast = fast;
        kernel._fastTier = null;
      }
      kernel.emitInfoChanged();
      return;
    }
    final tiers = kernel._tiersByModel[model] ?? const <KernelOption>[];
    if (tiers.isEmpty) return;
    // A switch: picking it again turns it off.
    final fast = model == kernel._modelId
        ? !kernel._fast
        : kernel._pickedFast[model] != true;
    kernel._pickedFast[model] = fast;
    if (model == kernel._modelId) {
      kernel._fast = fast;
      kernel._fastTier = fast ? tiers.first.id : null;
    }
    kernel.emitInfoChanged();
  }

  @override
  bool get toggle => true;
}

/// A server request this client answers with more than a decision.
class _Ask {
  const _Ask(this.rpcId, this.result);

  final Object? rpcId;
  final Map<String, Object?> Function(InteractionAnswer answer) result;
}

/// A file changed in a turn, as its patch leaves it, to put back.
class _EditedFile {
  const _EditedFile({
    required this.path,
    required this.diff,
    required this.kind,
    required this.original,
    this.moveTo,
  });

  final String path;
  final String diff;

  /// `add`, `delete`, or `update`.
  final String kind;

  /// Where it was moved to, for an update that moved it.
  final String? moveTo;

  /// What a deleted file had, to write back.
  final String original;
}
