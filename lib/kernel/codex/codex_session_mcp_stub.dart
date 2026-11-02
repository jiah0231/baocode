import '../../models/launch_environment.dart' show ProxyEndpoint;

class CodexSessionMcp {
  static Future<CodexSessionMcp> start({
    required String cwd,
    required String? Function() sessionId,
  }) => Future.error(UnsupportedError('Session MCP requires a desktop host.'));

  ProxyEndpoint get endpoint => throw UnsupportedError('No desktop host.');

  Map<String, Object?> configuration({ProxyEndpoint? endpoint}) =>
      throw UnsupportedError('No desktop host.');

  Future<void> close() async {}
}
