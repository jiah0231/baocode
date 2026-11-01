import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../usage/usage_capture.dart';
import '../../usage/usage_ledger.dart';
import '../codex/codex_accounts_io.dart';
import '../codex/codex_api.dart';
import '../codex/codex_service.dart';
import '../launch_environment.dart';
import '../model_provider.dart';
import '../upstream.dart';
import 'prompt_cache_key.dart';
import 'translate/openai_chat_request.dart';
import 'translate/claude_from_responses_request.dart';
import 'translate/openai_chat_response.dart';
import 'translate/responses_request.dart';
import 'translate/responses_from_claude_response.dart';
import 'translate/responses_response.dart';
import 'translate/thinking.dart';

/// Anthropic's Messages API on this machine, in front of the upstreams
/// that speak OpenAI's: Claude Code is pointed at it
/// (`ANTHROPIC_BASE_URL`), and each request is translated for the
/// upstream, and its answer back, as it streams (see translate/).
///
/// A request goes to the provider its path names, unless its model is
/// another's ([modelRef], `@<id>/<model>`: a role on another upstream
/// than the session's), as that one's model; at the endpoint that model
/// is spoken to at ([ModelProvider.protocolOf]). One of Anthropic's API is
/// passed its request as it came, only the key and its headers set here:
/// a session on it comes here when a role of it runs elsewhere, or one of
/// its models is spoken to through here.
///
/// Listens on 127.0.0.1 only, on a port of the system's choosing, and
/// answers only a request with its [token] (Claude Code's
/// `ANTHROPIC_AUTH_TOKEN`), made anew each run. The providers' keys stay
/// here: read as each request goes out, so a key changed applies at once.
///
/// A ChatGPT (Codex) provider's request goes as one of its accounts
/// ([CodexAccounts]): to another when that one is out of quota.
///
/// `/p/<provider>/v1/messages` and `/p/<provider>/v1/messages/count_tokens`
/// (an estimate: the upstreams have none).
class ModelProxy {
  ModelProxy({
    required this._provider,
    required this._key,
    this._onError,
    this._findProxy,
    this._codex,
    this._usage,
    @visibleForTesting String? token,
  }) : token = token ?? _newToken();

  final ModelProvider? Function(String id) _provider;

  /// The ChatGPT (Codex) providers' accounts.
  final CodexAccounts? _codex;
  final Future<String?> Function(String id) _key;
  final void Function(String id, String? error)? _onError;

  /// Where each request to an upstream is kept (see [UsageLedger]); none
  /// kept without it.
  final UsageLedger Function()? _usage;

  /// The HTTP proxy to reach the upstreams through, a connection each
  /// (the app's `NetworkProxy`); straight to them without one.
  final String Function(Uri url)? _findProxy;

  /// What a request must carry, as a bearer token or `x-api-key`.
  final String token;

  static String _newToken() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 32; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  Future<HttpServer>? _server;
  HttpClient? _client;
  final Set<Future<void>> _requests = {};
  Future<void>? _closing;
  Completer<void> _shutdown = Completer<void>();
  final Set<void Function()> _cancelCredentials = {};

  /// Where [providerId]'s requests go, the proxy started if not yet.
  Future<ProxyEndpoint> endpoint(String providerId) async {
    while (_closing case final closing?) {
      await closing;
    }
    if (_shutdown.isCompleted) _shutdown = Completer<void>();
    final server = await (_server ??= _bind());
    return (
      baseUrl:
          'http://127.0.0.1:${server.port}/p/${Uri.encodeComponent(providerId)}',
      token: token,
    );
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final handled = _handle(request);
      _requests.add(handled);
      unawaited(
        handled.then<void>(
          (_) => _requests.remove(handled),
          onError: (Object error, StackTrace stack) {
            _requests.remove(handled);
            debugPrint('Model proxy request: $error');
          },
        ),
      );
    });
    return server;
  }

  Future<HttpClient> _upstream() async {
    if (_shutdown.isCompleted) throw StateError('Model proxy is closing');
    if (_client case final client?) return client;
    return _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 30)
      ..findProxy = _findProxy ?? (_) => 'DIRECT';
  }

  Future<void> close() =>
      _closing ??= _close().whenComplete(() => _closing = null);

  Future<void> _close() async {
    if (!_shutdown.isCompleted) _shutdown.complete();
    for (final cancel in _cancelCredentials.toList()) {
      cancel();
    }
    final server = await _server;
    _server = null;
    _client?.close(force: true);
    _client = null;
    await server?.close(force: true);
    // A closed socket does not mean its handler's finally has run. Usage
    // is captured there, and must be enqueued before the app drains it.
    await Future.wait(_requests.toList());
  }

  /// Credentials may be waiting on a separate service, not our sockets.
  /// Let shutdown finish the request without waiting for that service.
  Future<T> _whileOpen<T>(Future<T> pending) {
    final result = Completer<T>();
    void cancel() {
      _cancelCredentials.remove(cancel);
      if (!result.isCompleted) {
        result.completeError(StateError('Model proxy is closing'));
      }
    }

    _cancelCredentials.add(cancel);
    unawaited(
      pending.then<void>(
        (value) {
          _cancelCredentials.remove(cancel);
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          _cancelCredentials.remove(cancel);
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    if (_shutdown.isCompleted) cancel();
    return result.future;
  }

  // --- A request -----------------------------------------------------------

  bool _authorized(HttpRequest request) {
    final bearer = request.headers.value(HttpHeaders.authorizationHeader);
    final given = switch (bearer) {
      final value? when value.startsWith('Bearer ') => value.substring(7),
      _ => request.headers.value('x-api-key'),
    };
    return given != null && _same(given.trim(), token);
  }

  /// In time that does not say how much of it matched.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    UsageMeter? meter;
    UsageLedger? ledger;
    try {
      if (!_authorized(request)) {
        return await _fail(response, 401, 'Not this proxy\'s token');
      }
      final segments = request.uri.pathSegments;
      if (request.method == 'POST' &&
          segments.length == 4 &&
          segments[0] == 'p' &&
          segments[2] == 'v1' &&
          segments[3] == 'responses') {
        return await _responses(request, response, segments[1]);
      }
      if (request.method != 'POST' ||
          segments.length < 4 ||
          segments[0] != 'p' ||
          segments[2] != 'v1' ||
          segments[3] != 'messages') {
        return await _fail(
          response,
          404,
          'No such endpoint: ${request.uri.path}',
        );
      }
      final providerId = segments[1];
      final text = await utf8.decodeStream(request);
      final body = jsonDecode(text);
      if (body is! Map<String, Object?>) {
        return await _fail(response, 400, 'The request is not a JSON object');
      }
      final countTokens = segments.length == 5 && segments[4] == 'count_tokens';
      if (segments.length != 4 && !countTokens) {
        return await _fail(
          response,
          404,
          'No such endpoint: ${request.uri.path}',
        );
      }
      // A model of another upstream (a subagent's, `@<id>/<model>`): to
      // that one, by its own name.
      var wanted = providerId;
      if (parseModelRef('${body['model'] ?? ''}') case (
        provider: final id,
        :final model,
      )) {
        wanted = id;
        body['model'] = model;
      }
      final found = wanted == builtinProviderId ? null : _provider(wanted);
      if (found == null) {
        return await _fail(response, 404, 'No such provider: $wanted');
      }
      // A model of an endpoint of its own (a relay's Claude at its Messages
      // API): spoken to there, its effort after its name as ever.
      final provider = found.speakingFor(
        parseSuffix('${body['model'] ?? ''}').modelName.trim(),
      );
      if (!countTokens) {
        ledger = _usage?.call();
        if (ledger != null && ledger.enabled) {
          meter = _meter(provider, body, request, text.length, ledger.detailed);
        }
      }
      if (provider.protocol == ProviderProtocol.anthropic) {
        return await _passThrough(
          provider,
          body,
          request,
          response,
          countTokens: countTokens,
          meter: meter,
        );
      }
      if (countTokens) {
        return await _json(response, 200, {
          'input_tokens': estimateInputTokens(body),
        });
      }
      await _forward(
        provider,
        body,
        response,
        sessionHeader: request.headers.value(sessionHeaderName),
        meter: meter,
      );
    } on FormatException catch (error) {
      meter?.fail('The request is not JSON: ${error.message}');
      await _fail(response, 400, 'The request is not JSON: ${error.message}');
    } on Object catch (error) {
      debugPrint('Model proxy: $error');
      meter?.fail('$error');
      await _fail(response, 502, '$error');
    } finally {
      if (meter?.finish(response.statusCode) case final call?) {
        ledger?.record(call);
      }
    }
  }

  /// `/p/<provider>/v1/responses`: what the Codex CLI sends, answered in
  /// its API. Its model names the provider it is for (`@<id>/<model>`,
  /// else the one in the path), whose protocol decides how it is asked:
  /// one of Responses is passed the request as it came (the key and the
  /// headers set here); the others are spoken to as Anthropic's, through
  /// this proxy's translations.
  Future<void> _responses(
    HttpRequest request,
    HttpResponse response,
    String providerId,
  ) async {
    try {
      final body = jsonDecode(await utf8.decodeStream(request));
      if (body is! Map<String, Object?>) {
        return await _failAs(
          response,
          400,
          'The request is not a JSON object',
          openAIError,
        );
      }
      final requested = parseSuffix('${body['model'] ?? ''}');
      var modelId = requested.modelName.trim();
      final suffix = requested.hasSuffix ? requested.rawSuffix.trim() : '';
      final fast = suffix.endsWith(fastModelSuffix);
      // The effort picked goes with the model's name, as Claude Code's does.
      final effort =
          (fast
                  ? suffix.substring(0, suffix.length - fastModelSuffix.length)
                  : suffix)
              .trim();
      final thinking = effort.isNotEmpty && effort != ThinkingLevel.none;
      var wanted = providerId;
      if (parseModelRef(modelId) case (provider: final id, :final model)) {
        wanted = id;
        modelId = model;
      }
      if (wanted == builtinProviderId) {
        return await _failAs(
          response,
          400,
          'Codex asks its own account for $modelId',
          openAIError,
        );
      }
      final found = _provider(wanted);
      if (found == null) {
        return await _failAs(
          response,
          404,
          'No such provider: $wanted',
          openAIError,
        );
      }
      final provider = found.speakingFor(modelId);
      final header = request.headers.value(sessionHeaderName);
      final session =
          sessionId(body, header: header) ??
          switch ('${body['prompt_cache_key'] ?? ''}'.trim()) {
            final key when key.isNotEmpty => key,
            _ => null,
          };
      final cacheKey = session == null ? null : promptCacheKeyOf(session);

      if (provider.protocol == ProviderProtocol.openaiResponses) {
        final outgoing = Map<String, Object?>.of(body)
          ..['model'] = modelId
          ..remove('client_metadata');
        if (fast) outgoing.putIfAbsent('service_tier', () => 'priority');
        if (provider.promptCacheKey) {
          outgoing['prompt_cache_key'] = cacheKey;
        } else {
          outgoing.remove('prompt_cache_key');
        }
        final lines = await _post(
          provider,
          outgoing,
          response,
          model: modelId,
          session: session,
        );
        if (lines == null) return;
        return await _relay(response, lines);
      }
      if (provider.protocol == ProviderProtocol.codex) {
        final outgoing = Map<String, Object?>.of(body)..['model'] = modelId;
        if (fast) outgoing.putIfAbsent('service_tier', () => 'priority');
        if (provider.promptCacheKey) {
          outgoing['prompt_cache_key'] = cacheKey;
        } else {
          outgoing.remove('prompt_cache_key');
        }
        final lines = await _openCodex(
          provider,
          body,
          outgoing,
          response,
          modelId,
          session,
          header,
          null,
          error: openAIError,
        );
        if (lines == null) return;
        return await _relay(response, lines);
      }

      // Chat Completions and Anthropic's: the request as Anthropic's,
      // its stream back as Responses'.
      final anthropic = provider.protocol == ProviderProtocol.anthropic;
      final claude = convertResponsesRequestToClaude(
        body,
        model: modelId,
        thinkingEffort: anthropic && thinking ? effort : null,
        maxTokens: anthropic ? 32000 : null,
      );
      final Stream<String> lines;
      if (anthropic) {
        final posted = await _post(
          provider,
          claude,
          response,
          model: modelId,
          session: session,
        );
        if (posted == null) return;
        lines = posted;
      } else {
        final outgoing = convertClaudeRequestToOpenAI(
          modelId,
          claude,
          true,
          preserveThinking: provider.preserveThinking,
        );
        if (thinking) {
          outgoing['reasoning_effort'] = effort;
        } else {
          outgoing.remove('reasoning_effort');
        }
        outgoing['stream_options'] = {'include_usage': true};
        final posted = await _post(
          provider,
          outgoing,
          response,
          model: modelId,
          session: session,
        );
        if (posted == null) return;
        lines = posted;
      }
      _startEvents(response);
      final chat = anthropic ? null : OpenAIChatResponseTranslator(claude);
      final translator = ResponsesFromClaudeTranslator();
      Future<void> writeClaude(List<String> frames) async {
        for (final frame in frames) {
          for (final part in const LineSplitter().convert(frame)) {
            final events = translator.convert(part);
            if (events.isEmpty) continue;
            for (final event in events) {
              response.write(event);
            }
          }
        }
        await response.flush();
      }

      await for (final line in lines) {
        if (chat == null) {
          final events = translator.convert(line);
          if (events.isEmpty) continue;
          for (final event in events) {
            response.write(event);
          }
          await response.flush();
        } else {
          await writeClaude(chat.convert(line));
        }
      }
      // The end, where the stream did not say it.
      if (chat != null) await writeClaude(chat.convert('data: [DONE]'));
      for (final event in translator.abort(
        '${provider.name} ended without a reply',
      )) {
        response.write(event);
      }
      await response.close();
    } on FormatException catch (error) {
      await _failAs(
        response,
        400,
        'The request is not JSON: ${error.message}',
        openAIError,
      );
    } on Object catch (error) {
      debugPrint('Model proxy: $error');
      await _failAs(response, 502, '$error', openAIError);
    }
  }

  /// [outgoing] to [provider] as a stream, its lines; null when it was
  /// answered here (it failed, in [openAIError]'s shape).
  Future<Stream<String>?> _post(
    ModelProvider provider,
    Map<String, Object?> outgoing,
    HttpResponse response, {
    required String model,
    String? session,
  }) async {
    final url = UpstreamUrls.endpoint(provider);
    if (url == null) {
      await _failAs(
        response,
        400,
        '${provider.name} has no valid base URL',
        openAIError,
      );
      return null;
    }
    final client = await _upstream();
    final upstream = await client.postUrl(url);
    final key = await _whileOpen(_key(provider.id));
    upstreamHeaders(provider, key).forEach(upstream.headers.set);
    customUpstreamHeaders(
      provider,
      session: session,
      model: model,
    ).forEach(upstream.headers.set);
    upstream.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'text/event-stream');
    upstream.add(utf8.encode(jsonEncode(outgoing)));
    unawaited(
      response.done.then<void>((_) {}, onError: (_) => upstream.abort()),
    );
    final answer = await upstream.close();
    if (answer.statusCode >= 400) {
      final text = await utf8.decodeStream(answer);
      final message = upstreamErrorMessage(answer.statusCode, text);
      _onError?.call(provider.id, message);
      await _failAs(response, answer.statusCode, message, openAIError);
      return null;
    }
    _onError?.call(provider.id, null);
    return answer
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
  }

  /// An upstream's [lines] passed on as they came: each `data:` line ends
  /// an event.
  static Future<void> _relay(
    HttpResponse response,
    Stream<String> lines,
  ) async {
    _startEvents(response);
    await for (final line in lines) {
      if (line.startsWith('data:')) {
        response.write('$line\n\n');
      } else if (line.isNotEmpty) {
        response.write('$line\n');
      }
      await response.flush();
    }
    return response.close();
  }

  /// Follows [body]'s request to [provider] for the [UsageLedger].
  UsageMeter _meter(
    ModelProvider provider,
    Map<String, Object?> body,
    HttpRequest request,
    int length,
    bool detailed,
  ) {
    final requested = parseSuffix('${body['model'] ?? ''}');
    final suffix = requested.hasSuffix ? requested.rawSuffix.trim() : '';
    final fast = suffix.endsWith(fastModelSuffix);
    final effort =
        (fast
                ? suffix.substring(0, suffix.length - fastModelSuffix.length)
                : suffix)
            .trim();
    return UsageMeter(
      provider: provider.id,
      providerName: provider.name,
      protocol: provider.protocol.name,
      model: requested.modelName.trim(),
      effort: effort.isEmpty ? null : effort,
      fast: fast,
      stream: body['stream'] == true,
      session: sessionId(
        body,
        header: request.headers.value(sessionHeaderName),
      ),
      requestBytes: length,
      info: analyzeRequest(body, request.headers.value, detailed: detailed),
    );
  }

  Future<void> _forward(
    ModelProvider provider,
    Map<String, Object?> body,
    HttpResponse response, {
    String? sessionHeader,
    UsageMeter? meter,
  }) async {
    // Claude Code's session id, for the custom headers' variables
    // ({{CLAUDE_SESSION_ID}}): the same its `metadata.user_id` carries.
    final session = sessionId(body, header: sessionHeader);
    final requested = parseSuffix('${body['model'] ?? ''}');
    final modelId = requested.modelName.trim();
    final suffix = requested.hasSuffix ? requested.rawSuffix.trim() : '';
    final fast = suffix.endsWith(fastModelSuffix);
    // The effort picked goes with the model's name: none, or `none`, and
    // reasoning is not asked for.
    final effort =
        (fast
                ? suffix.substring(0, suffix.length - fastModelSuffix.length)
                : suffix)
            .trim();
    final thinking = effort.isNotEmpty && effort != ThinkingLevel.none;
    final stream = body['stream'] == true;
    final Map<String, Object?> outgoing;
    if (provider.protocol == ProviderProtocol.openaiChat) {
      outgoing = convertClaudeRequestToOpenAI(
        modelId,
        body,
        stream,
        preserveThinking: provider.preserveThinking,
      );
      if (thinking) {
        outgoing['reasoning_effort'] = effort;
      } else {
        outgoing.remove('reasoning_effort');
      }
      if (stream) outgoing['stream_options'] = {'include_usage': true};
    } else {
      outgoing = convertClaudeRequestToResponses(
        modelId,
        body,
        reasoning: thinking,
      );
      if (thinking) {
        outgoing['reasoning'] = {'effort': effort, 'summary': reasoningSummary};
      }
      if (fast &&
          (provider.protocol == ProviderProtocol.openaiResponses ||
              provider.protocol == ProviderProtocol.codex) &&
          !body.containsKey('service_tier') &&
          !body.containsKey('speed')) {
        outgoing['service_tier'] = 'priority';
      }
    }
    if (provider.promptCacheKey) {
      if (promptCacheKey(body, header: sessionHeader) case final key?) {
        outgoing['prompt_cache_key'] = key;
      }
    }

    final HttpClientResponse? upstream;
    final Stream<String> lines;
    if (provider.protocol == ProviderProtocol.codex) {
      upstream = null;
      final opened = await _openCodex(
        provider,
        body,
        outgoing,
        response,
        modelId,
        session,
        sessionHeader,
        meter,
      );
      if (opened == null) return;
      lines = opened;
    } else {
      final url = UpstreamUrls.conversation(provider);
      if (url == null) {
        return _fail(response, 400, '${provider.name} has no valid base URL');
      }
      final client = await _upstream();
      final upstreamRequest = await client.postUrl(url);
      final key = await _whileOpen(_key(provider.id));
      upstreamHeaders(provider, key).forEach(upstreamRequest.headers.set);
      // The user's own headers after them: a name that may not be set is
      // left out, so none of the above is overwritten.
      customUpstreamHeaders(
        provider,
        session: session,
        model: modelId,
      ).forEach(upstreamRequest.headers.set);
      upstreamRequest.headers
        ..contentType = ContentType.json
        ..set(
          HttpHeaders.acceptHeader,
          stream || provider.protocol == ProviderProtocol.openaiResponses
              ? 'text/event-stream'
              : 'application/json',
        );
      upstreamRequest.add(utf8.encode(jsonEncode(outgoing)));
      // The client gone: so is the upstream's request.
      unawaited(
        response.done.then<void>(
          (_) {},
          onError: (_) => upstreamRequest.abort(),
        ),
      );
      final answer = upstream = await upstreamRequest.close();
      meter?.answered();
      if (answer.statusCode >= 400) {
        final text = await utf8.decodeStream(answer);
        final message = upstreamErrorMessage(answer.statusCode, text);
        meter?.fail(message);
        _onError?.call(provider.id, message);
        return _json(
          response,
          answer.statusCode,
          anthropicError(answer.statusCode, message),
        );
      }
      _onError?.call(provider.id, null);
      lines = answer
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
    }

    if (provider.protocol == ProviderProtocol.openaiChat) {
      if (!stream) {
        final text = await utf8.decodeStream(upstream!);
        meter?.upstreamLine(text);
        final message = convertOpenAIResponseToClaudeNonStream(body, text);
        meter?.message(message);
        return _json(response, 200, message);
      }
      _startEvents(response);
      final translator = OpenAIChatResponseTranslator(body);
      var done = false;
      await for (final line in lines) {
        if (line.trim() == 'data: [DONE]') done = true;
        meter?.upstreamLine(line);
        for (final frame in translator.convert(line)) {
          response.write(frame);
          meter?.events(frame);
        }
        await response.flush();
      }
      if (!done) {
        for (final frame in translator.convert('data: [DONE]')) {
          response.write(frame);
          meter?.events(frame);
        }
      }
      return response.close();
    }

    // Responses: the upstream streams either way.
    if (!stream) {
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        meter?.upstreamLine(line);
        final message = convertResponsesResponseToClaudeNonStream(
          body,
          line.substring(5).trim(),
        );
        if (message != null) {
          meter?.message(message);
          return _json(response, 200, message);
        }
      }
      meter?.fail('${provider.name} ended without a reply');
      return _fail(response, 502, '${provider.name} ended without a reply');
    }
    _startEvents(response);
    final translator = ResponsesResponseTranslator(body);
    await for (final line in lines) {
      meter?.upstreamLine(line);
      final events = translator.convert(line);
      if (events.isEmpty) continue;
      response.write(events);
      meter?.events(events);
      await response.flush();
    }
    return response.close();
  }

  /// What is not passed on between Claude Code and an upstream of
  /// Anthropic's API: what goes from one connection only, what is set here
  /// (the key), and the encoding, which the client here undoes.
  static const _notPassed = {
    'host',
    'authorization',
    'x-api-key',
    'proxy-authorization',
    'proxy-connection',
    'connection',
    'keep-alive',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'content-length',
    'accept-encoding',
    'content-encoding',
  };

  /// [body] to [provider], one of Anthropic's API, as Claude Code asked it
  /// (its headers too: its version, its betas), with the key and the
  /// provider's own headers set here; its answer back as it comes.
  ///
  /// A count of tokens the upstream refuses (many have none) is estimated.
  Future<void> _passThrough(
    ModelProvider provider,
    Map<String, Object?> body,
    HttpRequest request,
    HttpResponse response, {
    required bool countTokens,
    UsageMeter? meter,
  }) async {
    final messages = UpstreamUrls.messages(provider);
    if (messages == null) {
      return _fail(response, 400, '${provider.name} has no valid base URL');
    }
    final path = countTokens
        ? messages.replace(path: '${messages.path}/count_tokens')
        : messages;
    // Claude Code's query (`beta=true`) after the endpoint's own.
    final query = [
      path.query,
      request.uri.query,
    ].where((query) => query.isNotEmpty).join('&');
    final url = query.isEmpty ? path : path.replace(query: query);
    final client = await _upstream();
    final upstreamRequest = await client.postUrl(url);
    final key = await _whileOpen(_key(provider.id));
    upstreamHeaders(provider, key).forEach(upstreamRequest.headers.set);
    request.headers.forEach((name, values) {
      if (!_notPassed.contains(name) &&
          !UsageHeaders.hintsOnly.contains(name)) {
        upstreamRequest.headers.set(name, values);
      }
    });
    customUpstreamHeaders(
      provider,
      session: sessionId(
        body,
        header: request.headers.value(sessionHeaderName),
      ),
      model: '${body['model'] ?? ''}',
    ).forEach(upstreamRequest.headers.set);
    upstreamRequest.headers.contentType = ContentType.json;
    upstreamRequest.add(utf8.encode(jsonEncode(body)));
    unawaited(
      response.done.then<void>((_) {}, onError: (_) => upstreamRequest.abort()),
    );
    final answer = await upstreamRequest.close();
    meter?.answered();
    if (answer.statusCode >= 400) {
      final text = await utf8.decodeStream(answer);
      if (countTokens) {
        return _json(response, 200, {
          'input_tokens': estimateInputTokens(body),
        });
      }
      final message = upstreamErrorMessage(answer.statusCode, text);
      meter?.fail(message);
      _onError?.call(provider.id, message);
      _answerAs(response, answer);
      response.write(text);
      return response.close();
    }
    if (!countTokens) _onError?.call(provider.id, null);
    _answerAs(response, answer);
    response.bufferOutput = false;
    await for (final chunk in answer) {
      response.add(chunk);
      meter?.bytes(chunk);
      await response.flush();
    }
    return response.close();
  }

  /// [response] with [upstream]'s status and headers, but those
  /// [_notPassed].
  static void _answerAs(HttpResponse response, HttpClientResponse upstream) {
    response.statusCode = upstream.statusCode;
    upstream.headers.forEach((name, values) {
      if (_notPassed.contains(name)) return;
      for (final value in values) {
        response.headers.add(name, value);
      }
    });
  }

  /// Sends a Codex provider's request ([outgoing], as Responses) as one of
  /// its accounts, and gives the lines of its stream; null when it was
  /// answered here (it failed). An account out of quota, or signed out,
  /// gives way to the next; the reasoning replayed is dropped when the
  /// account taking it cannot read it (another's).
  ///
  /// A failure is answered as [error] says: in the API of whoever asked.
  Future<Stream<String>?> _openCodex(
    ModelProvider provider,
    Map<String, Object?> body,
    Map<String, Object?> outgoing,
    HttpResponse response,
    String modelId,
    String? session,
    String? sessionHeader,
    UsageMeter? meter, {
    Object Function(int status, String message) error = anthropicError,
  }) async {
    final codex = _codex;
    if (codex == null) {
      await _failAs(
        response,
        501,
        'ChatGPT accounts are not available here',
        error,
      );
      return null;
    }
    prepareCodexRequest(outgoing);
    final cacheKey = promptCacheKey(body, header: sessionHeader);
    // The user's own headers on the Codex backend too, with the same
    // session and model variables.
    final custom = customUpstreamHeaders(
      provider,
      session: session,
      model: modelId,
    );
    final client = await _upstream();
    final tried = <String>{};
    var stripped = false;
    String? lastError;
    var lastStatus = 429;
    while (true) {
      final account = codex.pick(provider, session: cacheKey, exclude: tried);
      if (account == null) {
        final back = codex.backAt(provider);
        final message = back != null
            ? [
                'Every ChatGPT account of ${provider.name} is out of quota '
                    'until ${back.toLocal().toString().substring(0, 16)}',
                ?lastError,
              ].join(': ')
            : lastError ??
                  (provider.accounts.isEmpty
                      ? '${provider.name} is not signed in to a ChatGPT account'
                      : 'No ChatGPT account of ${provider.name} can be used '
                            'now');
        // Not asked again and again by Claude Code till then, hours on.
        if (back != null) response.headers.set('x-should-retry', 'false');
        meter?.fail(message);
        _onError?.call(provider.id, message);
        await _json(response, lastStatus, error(lastStatus, message));
        return null;
      }
      String? rejected;
      for (var attempt = 0; attempt < 3; attempt++) {
        final String token;
        try {
          token = await _whileOpen(
            codex.accessToken(provider, account, rejected: rejected),
          );
        } on CodexException catch (error) {
          lastError = '${account.displayName}: ${error.message}';
          lastStatus = 401;
          tried.add(account.id);
          break;
        }
        final request = await client.postUrl(codex.endpoints.responses);
        codexHeaders(
          token,
          accountId: account.accountId,
          session: '${outgoing['prompt_cache_key'] ?? cacheKey ?? ''}',
          events: true,
          version: codexVersionOf(provider),
        ).forEach(request.headers.set);
        custom.forEach(request.headers.set);
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(outgoing)));
        unawaited(
          response.done.then<void>((_) {}, onError: (_) => request.abort()),
        );
        final upstream = await request.close();
        codex.record(provider, account, upstream.headers.value);
        final status = upstream.statusCode;
        if (status >= 400) {
          final text = await utf8.decodeStream(upstream);
          if (status == 401 && rejected == null) {
            rejected = token;
            continue;
          }
          if (status == 400 &&
              !stripped &&
              isInvalidEncryptedContent(text) &&
              stripReasoningItems(outgoing)) {
            stripped = true;
            continue;
          }
          final message = upstreamErrorMessage(status, text);
          if (codexLimitReset(status, text, DateTime.now()) case final until?) {
            codex.markLimited(provider, account, until);
          }
          if (status == 401 || status == 429) {
            codex.markError(provider, account, message);
            lastError = '${account.displayName}: $message';
            lastStatus = status;
            tried.add(account.id);
            break;
          }
          meter?.fail(message);
          _onError?.call(provider.id, message);
          await _json(response, status, error(status, message));
          return null;
        }
        // A limit reached may come as the stream's first event.
        final iterator = StreamIterator(
          upstream
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter()),
        );
        final head = <String>[];
        DateTime? limited;
        String? limitMessage;
        while (await iterator.moveNext()) {
          final line = iterator.current;
          head.add(line);
          if (!line.startsWith('data:')) continue;
          Object? event;
          try {
            event = jsonDecode(line.substring(5).trim());
          } on FormatException {
            event = null;
          }
          limited = codexLimitResetOf(event, DateTime.now());
          if (limited != null) {
            limitMessage = upstreamErrorMessage(429, line.substring(5).trim());
          }
          break;
        }
        if (limited != null) {
          await iterator.cancel();
          codex.markLimited(provider, account, limited);
          lastError = '${account.displayName}: $limitMessage';
          lastStatus = 429;
          tried.add(account.id);
          break;
        }
        codex.markError(provider, account, null);
        _onError?.call(provider.id, null);
        meter
          ?..answered()
          ..account = account.displayName;
        return _rest(head, iterator);
      }
      tried.add(account.id);
    }
  }

  static Stream<String> _rest(
    List<String> head,
    StreamIterator<String> rest,
  ) async* {
    yield* Stream.fromIterable(head);
    while (await rest.moveNext()) {
      yield rest.current;
    }
  }

  static void _startEvents(HttpResponse response) {
    response
      ..statusCode = 200
      ..bufferOutput = false
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Object? body,
  ) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  static Future<void> _fail(
    HttpResponse response,
    int status,
    String message,
  ) => _failAs(response, status, message, anthropicError);

  /// [message] as a failed request in [error]'s shape: Claude Code's
  /// ([anthropicError]) or Codex's ([openAIError]).
  static Future<void> _failAs(
    HttpResponse response,
    int status,
    String message,
    Object Function(int status, String message) error,
  ) async {
    try {
      await _json(response, status, error(status, message));
    } on Object {
      // Already answered, or the client gone.
      await response.close().catchError((_) {});
    }
  }
}

/// About how many tokens [request]'s input comes to: a quarter of its
/// text, as no upstream counts them.
int estimateInputTokens(Map<String, Object?> request) {
  final text = jsonEncode({
    'system': request['system'],
    'messages': request['messages'],
    'tools': request['tools'],
  });
  return (utf8.encode(text).length / 4).ceil();
}

/// The header Claude Code names its session in on every request: what
/// [sessionId] falls back on.
const sessionHeaderName = 'x-claude-code-session-id';

/// Claude Code's session id in [request]: the `session_id` of its
/// `metadata.user_id` (as JSON, or the older `…_session_<id>`), else its
/// [header] ([sessionHeaderName]), for a `metadata.user_id` the user set
/// themselves (`CLAUDE_CODE_EXTRA_BODY`, #307). Null without one. What a
/// custom header's `{{CLAUDE_SESSION_ID}}` stands for.
String? sessionId(Map<String, Object?> request, {String? header}) {
  final userId = switch (request['metadata']) {
    {'user_id': final String id} => id.trim(),
    _ => '',
  };
  var session = '';
  try {
    if (jsonDecode(userId) case {'session_id': final String id}) {
      session = id.trim();
    }
  } on FormatException {
    final legacy = userId.lastIndexOf('_session_');
    if (legacy >= 0) session = userId.substring(legacy + 9).trim();
  }
  if (session.isEmpty) session = header?.trim() ?? '';
  return session.isEmpty ? null : session;
}

/// The `prompt_cache_key` of [request]'s conversation: Claude Code's
/// session ([sessionId], [header] its fallback), hashed, so the upstream is
/// not told it. Null without one.
String? promptCacheKey(Map<String, Object?> request, {String? header}) {
  final session = sessionId(request, header: header);
  return session == null ? null : promptCacheKeyOf(session);
}
