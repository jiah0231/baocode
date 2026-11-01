import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../chat/chat_session.dart';
import '../chat/side_panel/side_panel_controller.dart';
import '../settings/user_settings.dart';
import 'learning_backend.dart';
import 'learning_controller.dart';
import 'learning_controls.dart';
import 'learning_models.dart';
import 'learning_preferences.dart';
import 'learning_scope.dart';

export 'learning_controls.dart';
export 'learning_scope.dart';

/// Owns the consent-gated projection while the actual chat is visible, not
/// while an optional side panel is open. Only ChatSession's LIVE event hook
/// supplies evidence: mounting this binding never scans a transcript.
class LearningSessionBinding extends StatefulWidget {
  const LearningSessionBinding({
    super.key,
    required this.session,
    required this.child,
    this.settings,
    this.active = true,
    this.preferences,
    this.generator,
  });

  final ChatSession session;
  final Widget child;
  final UserSettings? settings;

  /// False for a hidden/offstage or unfocused task. The chat host supplies its
  /// focus state so background panes do not spend explanation requests.
  final bool active;

  /// Optional test/host-owned preferences. The binding never disposes these.
  final LearningPreferences? preferences;

  /// Fake transport seam for tests. Consent is still required before enabling.
  final LearningGenerator? generator;

  @override
  State<LearningSessionBinding> createState() => _LearningSessionBindingState();
}

class _LearningSessionBindingState extends State<LearningSessionBinding> {
  // Multiple views of one task may coexist. Closing one must not cancel a
  // second visible view; weak session keys do not retain closed conversations.
  static final _visibleOwners = Expando<Set<Object>>();
  final Object _owner = Object();
  late ChatSession _session;
  late String _scopeKey;
  late LearningPreferences _preferences;
  bool _ownsPreferences = false;
  String? _configuration;
  String _languageCode = 'en';
  LearningController get _controller => _session.learning;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _session = widget.session;
    final settings = widget.settings;
    _scopeKey = _projectScope(_session);
    _ownsPreferences = widget.preferences == null;
    _preferences =
        widget.preferences ??
        (settings == null
            ? LearningPreferences.memory(scope: _scopeKey)
            : LearningPreferences.settings(settings, scope: _scopeKey));
    _preferences.addListener(_configure);
    _session.addListener(_sessionChanged);
    _configuration = null;
    _setVisibility();
  }

  String _projectScope(ChatSession session) {
    final location = session.kernelContext.cwd;
    final root = session.root;
    // Preserve the remote host identity, not only its /path component.
    return location == null && root == null
        ? 'session:${identityHashCode(session)}'
        : jsonEncode([location, root]);
  }

  void _sessionChanged() {
    if (_projectScope(_session) == _scopeKey) return;
    // Moving to another project/review root revokes sharing before any new
    // consent; existing cards remain owned by the conversation.
    _detach();
    _attach();
    _configure();
  }

  void _setVisibility() {
    final owners = _visibleOwners[_session] ??= <Object>{};
    if (widget.active) {
      owners.add(_owner);
    } else {
      owners.remove(_owner);
    }
    _controller.setActive(owners.isNotEmpty);
  }

  void _detach() {
    _session.removeListener(_sessionChanged);
    final owners = _visibleOwners[_session];
    owners?.remove(_owner);
    _controller.setActive(owners?.isNotEmpty ?? false);
    _preferences.removeListener(_configure);
    if (_ownsPreferences) _preferences.dispose();
  }

  @override
  void didUpdateWidget(LearningSessionBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.settings != widget.settings ||
        oldWidget.preferences != widget.preferences) {
      _detach();
      _attach();
      _configure();
    } else {
      if (oldWidget.active != widget.active) _setVisibility();
      if (oldWidget.generator != widget.generator) {
        _configuration = null;
        _configure();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _languageCode = Localizations.maybeLocaleOf(context)?.languageCode ?? 'en';
    _configure();
  }

  void _configure() {
    final configuration = '${_preferences.configurationToken}:$_languageCode';
    if (configuration == _configuration) return;
    _configuration = configuration;
    final paused = _controller.paused;
    if (_preferences.enabled) {
      _controller.enable(
        widget.generator ?? LearningBackend(preferences: _preferences),
        depth: _preferences.depth,
        languageCode: _languageCode,
        interval: _preferences.interval,
      );
      if (paused) _controller.setPaused(true);
    } else {
      _controller.disable(clearCards: false);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LearningScope(
    controller: _controller,
    preferences: _preferences,
    modelLabel: learningModelLabel(_preferences),
    child: widget.child,
  );
}

/// Compatibility surface only. The old rail no longer owns activation or
/// displays a second feed; explanations are attached to their chat operation.
class LearningSessionView extends StatelessWidget {
  const LearningSessionView({
    super.key,
    required this.session,
    required this.panel,
  });
  final ChatSession session;
  final AgentSidePanel panel;

  @override
  Widget build(BuildContext context) {
    if (LearningScope.maybeOf(context) == null) return const SizedBox.shrink();
    return const Align(
      alignment: Alignment.topRight,
      child: LearningControls(),
    );
  }
}
