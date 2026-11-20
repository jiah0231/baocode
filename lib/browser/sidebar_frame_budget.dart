import 'dart:convert';
import 'dart:typed_data';

/// Edge permits at most 1 MB from the native host to the extension.
/// Leave headroom below either definition of MB and check the complete UTF-8
/// JSON envelope, including the request ID and escaped character expansion.
const sidebarResultMaxBytes = 896 * 1024;

/// Encode a sidebar result without changing any unrelated bridge messages.
/// An oversized result is an explicit error, never an incomplete JSON frame.
Uint8List encodeSidebarResult(String requestId, Map<String, Object?> result) {
  Uint8List encode(Map<String, Object?> payload) => utf8.encode(jsonEncode({
    'type': 'sidebarChatResult',
    'requestId': requestId,
    'result': payload,
  }));

  final body = encode(result);
  if (body.length <= sidebarResultMaxBytes) return body;
  return encode(const {'error': 'frame_too_large'});
}
