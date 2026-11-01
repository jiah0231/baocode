/// How to start `codex app-server` for one session.
class CodexLaunch {
  const CodexLaunch({
    required this.cwd,
    this.resume,
    this.model,
    this.modelProvider,
    this.approvalPolicy,
    this.sandbox,
    this.effort,
    this.instructions,
    this.env,
  });

  /// The project directory it works in.
  final String cwd;

  /// A thread to continue, as its catalog listed it.
  final String? resume;

  final String? model;
  final String? modelProvider;
  final String? approvalPolicy;

  /// `read-only`, `workspace-write` or `danger-full-access`.
  final String? sandbox;
  final String? effort;

  /// Added to its base instructions, e.g. what the workspace is.
  final String? instructions;

  /// Environment given beside the login shell's.
  final Map<String, String>? env;

  CodexLaunch copyWith({String? cwd, String? resume}) => CodexLaunch(
    cwd: cwd ?? this.cwd,
    resume: resume ?? this.resume,
    model: model,
    modelProvider: modelProvider,
    approvalPolicy: approvalPolicy,
    sandbox: sandbox,
    effort: effort,
    instructions: instructions,
    env: env,
  );
}

typedef CodexTransportFactory = Future<CodexTransport> Function(
  CodexLaunch launch,
);

/// Codex's side of the adapter (the Adaptee): JSON-RPC 2.0 with
/// `codex app-server` over stdio, one message per line.
abstract interface class CodexTransport {
  /// Responses (`id` + `result`), notifications (`method` + `params`) and
  /// server requests (`id` + `method` + `params`, e.g. approvals), and
  /// last, when the process ends, a [CodexExit.type] message.
  Stream<Map<String, Object?>> get messages;

  /// Writes a request, or the response to a server request.
  void write(Map<String, Object?> message);

  /// Ends the process.
  void close();

  /// Completes once the process is gone, closed or not.
  Future<void> get exited;
}

/// The message a transport ends with: the process is gone.
abstract final class CodexExit {
  static const type = 'transport_exit';

  /// [executable] is the CLI run, where the transport knows it.
  static Map<String, Object?> message(
    int code,
    String stderr, {
    String? executable,
  }) => {
    'type': type,
    'code': code,
    'stderr': stderr,
    'executable': ?executable,
  };

  static bool isExit(Map<String, Object?> message) => message['type'] == type;
}

/// Codex is not on the machine, could not start, or is too old.
class CodexUnavailable implements Exception {
  const CodexUnavailable(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;
}

/// The project folder Codex was to work in is not there.
class CodexFolderGone extends CodexUnavailable {
  CodexFolderGone(this.folder) : super('The project folder is gone: $folder');

  final String folder;
}
