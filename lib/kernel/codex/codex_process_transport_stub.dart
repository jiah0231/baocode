import 'codex_transport.dart';
import 'codex_path_setting.dart';

/// No processes on the web.
abstract final class CodexProcessTransport {
  static Future<CodexTransport> start(CodexLaunch launch) async =>
      throw const CodexUnavailable(
        'Codex cannot run in a browser',
        detail: 'Open this project in the desktop app.',
      );

  static Future<CodexTransport> startCatalog() async =>
      throw const CodexUnavailable(
        'Codex cannot run in a browser',
        detail: 'Open this project in the desktop app.',
      );

  static Future<LocalCodexStatus?> status() async => null;

  static Future<void> stopAll() async {}

  static Future<void> reapLeftovers() async {}
}
