import 'dart:async';

import 'package:flutter/widgets.dart';

import '../chat/chat_session.dart';
import '../chat/side_panel/file_open.dart';
import '../chat/side_panel/side_panel_controller.dart';
import '../models/model_providers.dart';
import 'learning_backend.dart';
import 'learning_controller.dart';
import 'learning_models.dart';
import 'learning_panel.dart';
import 'learning_preferences.dart';
import 'learning_settings_dialog.dart';

/// Binds the opt-in teaching projection to the visible conversation only.
/// Cards are session-owned, while leaving this page cancels background work.
class LearningSessionView extends StatefulWidget {
  const LearningSessionView({
    super.key,
    required this.session,
    required this.panel,
  });
  final ChatSession session;
  final AgentSidePanel panel;

  @override
  State<LearningSessionView> createState() => _LearningSessionViewState();
}

class _LearningSessionViewState extends State<LearningSessionView> {
  late LearningPreferences _preferences;
  String? _configuration;
  String _languageCode = 'en';
  LearningController get _controller => widget.session.learning;

  @override
  void initState() {
    super.initState();
    final settings = widget.panel.settings;
    final scope =
        widget.session.root ?? 'session:${identityHashCode(widget.session)}';
    _preferences = settings == null
        ? LearningPreferences.memory(scope: scope)
        : LearningPreferences.settings(settings, scope: scope);
    _preferences.addListener(_configure);
    _controller.setActive(true);
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
        LearningBackend(preferences: _preferences),
        depth: _preferences.depth,
        languageCode: _languageCode,
        interval: _preferences.interval,
      );
      if (paused) _controller.setPaused(true);
    } else {
      // Revoked consent stops sharing without discarding this session's cards.
      // The explicit Turn off action below is the only clearing action.
      _controller.disable(clearCards: false);
    }
    if (mounted) setState(() {});
  }

  void _openEvidence(LearningEvidence evidence) {
    // Never open a model-generated path: only exact host-observed anchors.
    if (evidence.path case final path?) {
      widget.panel.open(
        widget.session,
        FileOpenRequest(path, preview: true, readOnly: true),
      );
    }
  }

  @override
  void dispose() {
    _controller.setActive(false);
    _preferences.removeListener(_configure);
    _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => LearningPanel(
      cards: _controller.cards,
      enabled: _controller.enabled,
      paused: _controller.paused,
      busy: _controller.busy,
      budgetReached: _controller.budgetReached,
      error: _controller.error,
      modelLabel: LearningBackend.modelLabel(
        _preferences.modelRef,
        ModelProviders.current,
      ),
      sessionKey: '${identityHashCode(widget.session)}',
      onConfigure: () => unawaited(
        showLearningSettingsDialog(
          context,
          preferences: _preferences,
          providers: ModelProviders.current,
        ),
      ),
      onTogglePause: () => _controller.setPaused(!_controller.paused),
      onDisable: () {
        // Cancel immediately, even if saving preferences is slow or fails.
        _controller.disable();
        unawaited(_preferences.disable().catchError((Object _) {}));
      },
      onOpenEvidence: _openEvidence,
    ),
  );
}
