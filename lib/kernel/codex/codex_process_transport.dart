import 'codex_process_transport_stub.dart'
    if (dart.library.io) 'codex_process_transport_io.dart'
    as platform;
import 'codex_transport.dart';
import 'codex_path_setting.dart';

/// Starts `codex app-server` locally; on the web, where there are no
/// processes, fails saying so.
Future<CodexTransport> startCodexProcess(CodexLaunch launch) =>
    platform.CodexProcessTransport.start(launch);

/// Starts one to read the sessions it keeps, not to work in a project.
Future<CodexTransport> startCodexCatalogServer() =>
    platform.CodexProcessTransport.startCatalog();

/// Ends every Codex process the app started, and waits for them: for when
/// the app quits.
Future<void> stopCodexProcesses() => platform.CodexProcessTransport.stopAll();

/// Ends the Codex processes an earlier run of the app left running (a
/// crash, a force quit, a hot restart); none on the web.
Future<void> reapCodexProcesses() =>
    platform.CodexProcessTransport.reapLeftovers();

/// The CLI used by local sessions, without downloading or changing it.
Future<LocalCodexStatus?> localCodexStatus() =>
    platform.CodexProcessTransport.status();
