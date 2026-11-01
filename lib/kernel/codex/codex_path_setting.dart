/// Settings → General → Codex: a local CLI override. Remote hosts keep
/// using their own PATH; this machine's paths are never sent over SSH.
abstract final class CodexPathSetting {
  static const settingKey = 'codex.path';

  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// Read at each local launch, including history/catalog requests.
  static String? Function() current = () => null;
}

sealed class LocalCodexStatus {
  const LocalCodexStatus();
}

class LocalCodexFound extends LocalCodexStatus {
  const LocalCodexFound(this.path, this.version);
  final String path;
  final String? version;
}

class LocalCodexMissing extends LocalCodexStatus {
  const LocalCodexMissing();
}

class LocalCodexFailed extends LocalCodexStatus {
  const LocalCodexFailed(this.message);
  final String message;
}
