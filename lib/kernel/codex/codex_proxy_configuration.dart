/// Process-local configuration for BaoCode's own model proxy. The token is
/// inherited through the child environment, never a command-line argument.
class CodexProxyConfiguration {
  const CodexProxyConfiguration({required this.baseUrl, required this.token});

  static const providerId = 'baocode';
  static const tokenVariable = 'BAOCODE_CODEX_PROXY_TOKEN';

  final String baseUrl;
  final String token;

  Map<String, Object> get provider => {
    'name': 'BaoCode',
    'base_url': '$baseUrl/v1',
    'wire_api': 'responses',
    'env_key': tokenVariable,
    'supports_websockets': false,
  };

  Map<String, String> get environment => {tokenVariable: token};

  /// Native Codex validates its current process provider before resume and
  /// input. A thread/start or thread/resume override alone is insufficient.
  List<String> get arguments => [
    '-c',
    "model_provider='$providerId'",
    for (final entry in provider.entries) ...[
      '-c',
      'model_providers.$providerId.${entry.key}=${_value(entry.value)}',
    ],
  ];

  static String _value(Object value) {
    if (value is bool) return '$value';
    final text = value as String;
    // These are app-owned identifiers and a generated loopback URL. Literal
    // TOML strings keep Windows npm shims free of embedded double quotes.
    if (text.contains(RegExp('[\'"\\r\\n]'))) {
      throw ArgumentError('Invalid Codex proxy configuration value');
    }
    return "'$text'";
  }
}
