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
  late String token;

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
      'capability': token, 'session_id': 'claude:target',
    }},
  };

  setUp(() async {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = _LoopbackHttpOverrides();
    client = HttpClient();
    service = SessionQueryService(read: (id) async => SessionQuerySnapshot(
      targetId: id, title: 'Claude target', kernel: 'Claude Code', messages: const [
        SessionQueryMessage(index: 0, role: 'assistant', text: 'requested history'),
      ],
    ))..register();
    token = service.grant(['claude:target'],
      callerSessionId: () => 'source', callerCwd: '/project');
    bridge = await CodexSessionMcp.start(cwd: '/project', sessionId: () => 'source');
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
    final other = await CodexSessionMcp.start(cwd: '/project', sessionId: () => 'other');
    addTearDown(other.close);
    final result = await request(call(), server: other);
    expect(jsonDecode(result.body)['result']['isError'], true);
    expect(result.body, isNot(contains('requested history')));
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
