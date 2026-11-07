import '../chat/chat_session.dart';
import '../kernel/agent_kernel.dart';
import '../models/model_provider.dart';
import '../models/model_providers.dart';
import '../workspace/workspace.dart';

/// The destination captured before a selection popup takes focus. This is a
/// new normal agent, not a continuation or fork of the source conversation.
class QuickAskAgentHandoff {
  QuickAskAgentHandoff(this.workspace, this.source)
    : project = source.project,
      kernel = source.kernel,
      settings = Map.unmodifiable({
        ...source.session.kernelContext.settings,
        for (final kind in KernelChoiceKind.values)
          kind.name: ?source.session.selected(kind),
        // Acting is intentional; approvals and sandbox remain as captured.
        KernelChoiceKind.mode.name: 'agent',
      });

  final Workspace workspace;
  final AgentThread source;
  final Project project;
  final KernelDescriptor kernel;
  final Map<String, String> settings;
  bool _attempted = false;

  String get label => '${kernel.label} · ${project.name}';

  /// Null means no confirmed handoff. Once dispatch was attempted, do not
  /// retry: a thrown transport call may already have sent the first turn.
  AgentThread? submit(String prompt) {
    if (_attempted ||
        prompt.trim().isEmpty ||
        !_modelAvailable ||
        source.project.path != project.path ||
        !workspace.threads.contains(source)) {
      return null;
    }
    _attempted = true;
    try {
      final thread = workspace.startFreshAgent(
        source,
        kernel: kernel,
        settings: settings,
      );
      if (thread == null || !thread.session.canSend) return null;
      // A kernel may normalize unsupported initial choices. Never dispatch
      // captured text if that silently changes its model/provider route.
      final capturedModel = settings[KernelChoiceKind.model.name];
      if (capturedModel != null &&
          thread.session.selected(KernelChoiceKind.model) != capturedModel) {
        return null;
      }
      thread.session.send(
        ComposerMessage(text: prompt),
        from: UserPlace.computer,
      );
      return thread;
    } on Object {
      // Keep the new thread available for normal error/permission UI. Do not
      // discard a conversation whose dispatch outcome may be uncertain.
      return null;
    }
  }

  // Kernel model resolution may deliberately fall back when a provider/model
  // disappears. A captured selection must not be sent to a different route.
  bool get _modelAvailable {
    final picked = settings[KernelChoiceKind.model.name];
    if (picked?.startsWith('@') != true) return true;
    final ref = parseModelRef(picked);
    final provider = ModelProviders.current.provider(ref?.provider);
    final model = ref == null ? null : provider?.model(ref.model);
    return provider != null &&
        provider.enabled &&
        provider.connected &&
        model != null &&
        model.enabled &&
        !model.missing &&
        !model.kind.generatesImages;
  }
}
