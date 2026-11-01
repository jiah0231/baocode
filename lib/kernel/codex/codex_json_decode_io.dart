import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

/// Small notifications stay cheap; large history/tool-result lines are parsed
/// away from the UI isolate. The transport's asyncMap preserves wire order and
/// drains these futures before reporting stdout completion.
FutureOr<Object?> decodeCodexJson(
  String line, {
  int offloadAt = 64 * 1024,
  Future<Object?> Function(String)? decodeLarge,
}) {
  if (line.length < offloadAt) return jsonDecode(line);
  return (decodeLarge ?? _decodeAway)(line);
}

Future<Object?> _decodeAway(String line) => Isolate.run(() => jsonDecode(line));
