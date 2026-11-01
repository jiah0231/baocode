import 'dart:async';

import '../kernel/codex/codex_transport.dart';
import '../remote/remote_codex.dart';

typedef CodexSettingsRequest = Future<Map<String, Object?>> Function(
  String method,
  Map<String, Object?> params,
);

/// One short-lived app-server for settings. Unsupported methods surface as
/// errors, rather than treating a failed write as a successful toggle.
Future<T> withCodexSettings<T>(
  String? location,
  Future<T> Function(CodexSettingsRequest request) body,
) async {
  final transport = await startCodexCatalogServerFor(location);
  final pending = <int, Completer<Map<String, Object?>>>{};
  var serial = 0;
  void stopped() {
    for (final request in pending.values) {
      if (!request.isCompleted) {
        request.completeError(
          const CodexUnavailable('Codex settings server stopped'),
        );
      }
    }
    pending.clear();
  }

  final subscription = transport.messages.listen((message) {
    if (CodexExit.isExit(message)) {
      stopped();
      return;
    }
    final result = pending.remove(message['id']);
    if (result == null) return;
    if (message['error'] case final Map error) {
      result.completeError(
        CodexUnavailable(
          'Codex ${error['code']}: ${error['message']}. '
          'This installed version may not support this setting.',
        ),
      );
    } else {
      result.complete(
        (message['result'] as Map?)?.cast<String, Object?>() ?? {},
      );
    }
  });
  unawaited(transport.exited.then((_) => stopped()));
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++serial;
    final result = Completer<Map<String, Object?>>();
    pending[id] = result;
    transport.write({'id': id, 'method': method, 'params': params});
    return result.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        pending.remove(id);
        throw CodexUnavailable('Codex did not answer $method');
      },
    );
  }

  try {
    await request('initialize', {
      'clientInfo': {'name': 'baocode', 'version': '1.0.0'},
      'capabilities': {'experimentalApi': true},
    });
    transport.write({'method': 'initialized', 'params': <String, Object?>{}});
    return await body(request);
  } finally {
    await subscription.cancel();
    transport.close();
    await transport.exited.timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    stopped();
  }
}
