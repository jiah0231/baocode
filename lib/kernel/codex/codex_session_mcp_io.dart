import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../chat/session_query.dart';
import '../../models/launch_environment.dart' show ProxyEndpoint;
import '../claude_code/claude_sdk_tools.dart';

/// An authenticated, per-source Streamable HTTP MCP endpoint for saved Codex
/// threads whose dynamic tool catalogue predates @session. It exposes only
/// session_query; the ordinary SDK gate and per-turn grants still apply.
class CodexSessionMcp {
  CodexSessionMcp._(this._server, this._cwd, this._sessionId, this._turnId, this._token);

  final HttpServer _server;
  final String _cwd;
  final String? Function() _sessionId;
  final String? Function() _turnId;
  final String _token;
  final _closed = Completer<void>();
  int _active = 0;

  static Future<CodexSessionMcp> start({
    required String cwd,
    required String? Function() sessionId,
    required String? Function() turnId,
  }) async {
    final random = Random.secure();
    final token = List.generate(32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bridge = CodexSessionMcp._(server, cwd, sessionId, turnId, token);
    server.listen(
      (request) => unawaited(bridge._handle(request)),
      onError: (Object _) {
        unawaited(bridge.close().catchError((Object _) {}));
      },
    );
    return bridge;
  }

  ProxyEndpoint get endpoint => (
    baseUrl: 'http://127.0.0.1:${_server.port}/mcp', token: _token,
  );

  /// A caller may pass the same authenticated endpoint forwarded over the
  /// project's existing SSH connection. No credentials enter the model prompt.
  Map<String, Object?> configuration({ProxyEndpoint? endpoint}) {
    final selected = endpoint ?? this.endpoint;
    return {
      'mcp_servers': {
        'baocode_session': {
          'enabled': true,
          'url': selected.baseUrl,
          'http_headers': {'Authorization': 'Bearer ${selected.token}'},
          'enabled_tools': [SessionQueryService.toolName],
          'startup_timeout_sec': 10,
          'tool_timeout_sec': 35,
        },
      },
    };
  }

  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    var counted = false;
    try {
      final response = request.response;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (_closed.isCompleted) {
        response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      if (request.headers.value('origin') != null ||
          request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $_token') {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.uri.path != '/mcp') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      // No server-initiated SSE channel is needed for this read-only tool.
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('allow', 'POST');
        return;
      }
      if (_active >= 8) {
        response.statusCode = HttpStatus.tooManyRequests;
        return;
      }
      _active++;
      counted = true;
      if (request.headers.contentType?.mimeType != 'application/json') {
        response.statusCode = HttpStatus.unsupportedMediaType;
        return;
      }
      if (request.contentLength > 65536) {
        response.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
      // Authenticated ingress binds identity before any await: a slow old body
      // cannot acquire a later turn's selected targets.
      final call = _call();
      final bytes = await _readBody(request);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['jsonrpc'] != '2.0') {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      final message = decoded.cast<String, Object?>();
      final method = message['method'];
      final id = message['id'];
      if (id != null && id is! String && id is! num) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      final params = (message['params'] as Map?)?.cast<String, Object?>() ?? {};
      if (id == null) {
        if (method == 'notifications/initialized' || method == 'notifications/cancelled') {
          if (method == 'notifications/cancelled') {
            await ClaudeSdkTools.handle({...message, 'params': {
              ...params, 'requestId': 'session-mcp:${_server.port}:${params['requestId']}',
            }}, call);
          }
          response.statusCode = HttpStatus.accepted;
        } else {
          response.statusCode = HttpStatus.badRequest;
        }
        return;
      }
      Map<String, Object?> result;
      switch (method) {
        case 'initialize':
          const supported = ['2025-11-25', '2025-06-18', '2025-03-26'];
          final version = params['protocolVersion'];
          result = {'jsonrpc': '2.0', 'id': id, 'result': {
            'protocolVersion': supported.contains(version) ? version : supported.first,
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'baocode_session', 'version': '1.0.0'},
          }};
        case 'ping':
          result = {'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}};
        case 'tools/list':
          result = await ClaudeSdkTools.handle(message, call);
          final body = result['result'] as Map;
          body['tools'] = [
            for (final tool in body['tools'] as List)
              if ((tool as Map)['name'] == SessionQueryService.toolName)
                {...tool, 'annotations': {
                  'readOnlyHint': true, 'destructiveHint': false,
                }},
          ];
        case 'tools/call' when params['name'] == SessionQueryService.toolName:
          result = await ClaudeSdkTools.handle({
            ...message, 'id': 'session-mcp:${_server.port}:$id',
          }, call).timeout(const Duration(seconds: 35));
          result['id'] = id;
        default:
          result = {'jsonrpc': '2.0', 'id': id, 'error': {
            'code': -32601, 'message': 'Method or tool not available.',
          }};
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result));
    } on _McpBodyTooLarge {
      try {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
      } on Object { /* disconnected */ }
    } on Object {
      // Never echo body, auth header, cursor or internal exception details.
      try { request.response.statusCode = HttpStatus.badRequest; } on Object { /* closed */ }
    } finally {
      if (counted) _active--;
      try { await request.response.close().timeout(const Duration(seconds: 2)); } on Object { /* disconnected */ }
    }
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final chunks = StreamIterator<List<int>>(request);
    Future<List<int>> collect() async {
      final bytes = <int>[];
      while (await chunks.moveNext()) {
        if (bytes.length + chunks.current.length > 65536) {
          throw const _McpBodyTooLarge();
        }
        bytes.addAll(chunks.current);
      }
      return bytes;
    }
    try {
      // Total deadline, not an idle timeout that slow chunks can renew.
      return await collect().timeout(const Duration(seconds: 10));
    } on _McpBodyTooLarge {
      // Cancelling an unread HttpRequest can close its socket. Flush the
      // rejection first so chunked clients receive 413 rather than a reset.
      request.response.statusCode = HttpStatus.requestEntityTooLarge;
      request.response.persistentConnection = false;
      await request.response.close().timeout(const Duration(seconds: 2));
      rethrow;
    } finally {
      await chunks.cancel();
    }
  }

  ClaudeSdkCall _call() => ClaudeSdkCall(
    cwd: _cwd, sessionId: _sessionId(), turnId: _turnId(), cancelled: _closed.future,
  );
}

class _McpBodyTooLarge implements Exception {
  const _McpBodyTooLarge();
}
