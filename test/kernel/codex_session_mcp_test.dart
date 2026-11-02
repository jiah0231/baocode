import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_session_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

class _DenyGate implements ClaudeSdkGate {
  @override
  bool offersTool(String cwd, String tool) => false;
  @override
  bool tellsFeature(String cwd, String feature) => false;
  @override
  bool asksUser(String cwd) => false;
}

// Real sockets only to this test's loopback MCP server, never external hosts.
class _LoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final address = InternetAddress.tryParse(uri.host);
      if (proxyHost != null || address == null || !address.isLoopback) {
        throw StateError('Fixture HTTP must stay on loopback: $uri');
      }
      return Socket.startConnect(address, uri.port);
    };
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides? previousHttpOverrides;
  late CodexSessionMcp bridge;
  late SessionQueryService service;
  late HttpClient client;
  String? activeTurn;
  var reads = 0;

  Future<({int status, String body})> request(Map<String, Object?> body, {
    bool authorized = true, bool origin = false, String method = 'POST',
    CodexSessionMcp? server,
  }) async {
    final endpoint = (server ?? bridge).endpoint;
    final request = await client.openUrl(method, Uri.parse(endpoint.baseUrl));
    request.headers.contentType = ContentType.json;
    if (authorized) request.headers.set('Authorization', 'Bearer ${endpoint.token}');
    if (origin) request.headers.set('Origin', 'https://untrusted.invalid');
    if (method == 'POST') request.write(jsonEncode(body));
    final response = await request.close();
    return (status: response.statusCode, body: await utf8.decodeStream(response));
  }

  Map<String, Object?> call() => {
    'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
    'params': {'name': 'session_query', 'arguments': {
      'session_id': 'claude:target',
    }},
  };

  setUp(() async {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = _LoopbackHttpOverrides();
    client = HttpClient();
    reads = 0;
    service = SessionQueryService(read: (id) async {
      reads++;
      return SessionQuerySnapshot(
      targetId: id, title: 'Claude target', kernel: 'Claude Code', messages: const [
        SessionQueryMessage(index: 0, role: 'assistant', text: 'requested history'),
      ],
      );
    })..register();
    activeTurn = 'turn';
    service.grant(['claude:target'], callerTurnId: 'turn', isActive: () => activeTurn == 'turn',
      callerSessionId: () => 'source', callerCwd: '/project');
    bridge = await CodexSessionMcp.start(cwd: '/project', sessionId: () => 'source', turnId: () => activeTurn);
  });
  tearDown(() async {
    client.close(force: true);
    HttpOverrides.global = previousHttpOverrides;
    await bridge.close();
    service.dispose();
    ClaudeSdkTools.unregister('unrelated');
    ClaudeSdkTools.gate = null;
  });

  test('HTTP initialization, discovery and source-bound selected query', () async {
    final init = await request({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
      'params': {'protocolVersion': '2025-06-18'}});
    expect(init.status, 200);
    expect(jsonDecode(init.body)['result']['protocolVersion'], '2025-06-18');
    final listed = await request({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    final tools = jsonDecode(listed.body)['result']['tools'] as List;
    expect(tools.map((tool) => tool['name']), ['session_query']);
    final response = await request(call());
    expect(response.status, 200);
    expect(jsonDecode(response.body)['id'], 3);
    expect(response.body, contains('requested history'));
    final config = bridge.configuration()['mcp_servers'] as Map;
    expect(config['baocode_session']['enabled_tools'], ['session_query']);
  });

  test('authentication, browser origin and GET rejected', () async {
    expect((await request(call(), authorized: false)).status, 403);
    expect((await request(call(), origin: true)).status, 403);
    expect((await request({}, method: 'GET')).status, 405);
  });

  test('oversized authenticated body is rejected before dispatch', () async {
    final result = await request({'jsonrpc': '2.0', 'id': 1,
      'method': 'tools/call', 'padding': 'x' * 65537});
    expect(result.status, 413);
  });

  test('unrelated SDK tools never exposed or callable', () async {
    var ran = false;
    ClaudeSdkTools.register(ClaudeSdkTool(name: 'unrelated', description: 'secret',
      inputSchema: {}, run: (_, _) async { ran = true; return 'no'; }));
    final listed = await request({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
    expect(listed.body, isNot(contains('unrelated')));
    final result = await request({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
      'params': {'name': 'unrelated', 'arguments': {}}});
    expect(jsonDecode(result.body)['error']['code'], -32601);
    expect(ran, false);
  });

  test('endpoint identity cannot borrow another source capability', () async {
    final other = await CodexSessionMcp.start(cwd: '/project', sessionId: () => 'other', turnId: () => activeTurn);
    addTearDown(other.close);
    final result = await request(call(), server: other);
    expect(jsonDecode(result.body)['result']['isError'], true);
    expect(result.body, isNot(contains('requested history')));
  });

  test('missing and replaced host turns deny selected targets', () async {
    for (final turn in [null, 'other-turn']) {
      activeTurn = turn;
      final result = await request(call());
      expect(jsonDecode(result.body)['result']['isError'], true);
      expect(result.body, isNot(contains('requested history')));
    }
  });

  test('slow HTTP body retains its original host turn instead of acquiring the next', () async {
    final endpoint = bridge.endpoint;
    final uri = Uri.parse(endpoint.baseUrl);
    final socket = await Socket.connect(uri.host, uri.port);
    addTearDown(socket.destroy);
    final response = StringBuffer();
    final continued = Completer<void>();
    final done = Completer<void>();
    socket.transform(utf8.decoder).listen((part) {
      response.write(part);
      if (!continued.isCompleted && response.toString().contains('100 Continue\r\n\r\n')) {
        continued.complete();
      }
    }, onDone: () => done.complete(), onError: (Object error, StackTrace stack) {
      if (!continued.isCompleted) continued.completeError(error, stack);
      if (!done.isCompleted) done.completeError(error, stack);
    });
    final body = jsonEncode(call());
    socket.write('POST /mcp HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\n'
        'Authorization: Bearer ${endpoint.token}\r\n'
        'Content-Type: application/json\r\nContent-Length: ${utf8.encode(body).length}\r\n'
        'Expect: 100-continue\r\nConnection: close\r\n\r\n');
    await socket.flush();
    // HttpServer sends Continue when the handler listens to the body, after
    // capturing source context. This is an ingress barrier, not a timing sleep.
    await continued.future.timeout(const Duration(seconds: 5));
    final half = body.length ~/ 2;
    socket.write(body.substring(0, half));
    await socket.flush();
    activeTurn = 'next-turn';
    service.grant(['claude:target'], callerSessionId: () => 'source',
      callerCwd: '/project', callerTurnId: 'next-turn',
      isActive: () => activeTurn == 'next-turn');
    socket.write(body.substring(half));
    await socket.flush();
    await done.future.timeout(const Duration(seconds: 5));
    expect(response.toString(), contains('"isError":true'));
    expect(response.toString(), isNot(contains('requested history')));
    expect(reads, 0);
    final fresh = await request(call());
    expect(fresh.body, contains('requested history'));
    expect(jsonDecode(fresh.body)['result']['isError'], isNot(true));
    expect(reads, 1);
  });

  test('HTTP fallback does not bypass the existing SDK ability gate', () async {
    ClaudeSdkTools.gate = _DenyGate();
    final listed = await request({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
    expect(jsonDecode(listed.body)['result']['tools'], isEmpty);
    final result = await request(call());
    expect(jsonDecode(result.body)['result']['isError'], true);
    expect(result.body, isNot(contains('requested history')));
  });

  test('notifications accepted without executing a call', () async {
    final result = await request({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    expect(result.status, 202);
    final notificationCall = call()..remove('id');
    expect((await request(notificationCall)).status, 400);
  });
}
