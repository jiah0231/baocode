import 'codex_install_stub.dart'
    if (dart.library.io) 'codex_install_io.dart'
    as platform;

/// A complete official package, not the standalone binary without helpers.
class CodexInstallRelease {
  const CodexInstallRelease({
    required this.version,
    required this.target,
    required this.url,
    required this.sha256,
    required this.size,
  });
  final String version;
  final String target;
  final Uri url;
  final String sha256;
  final int size;

  /// Validate again at the install boundary, including callers that did not use
  /// release metadata parsing. The version also becomes a directory component.
  void validate() {
    const targets = {
      'x86_64-pc-windows-msvc',
      'aarch64-pc-windows-msvc',
      'x86_64-apple-darwin',
      'aarch64-apple-darwin',
      'x86_64-unknown-linux-musl',
      'aarch64-unknown-linux-musl',
    };
    if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version) ||
        !targets.contains(target) ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256) ||
        size <= 0 ||
        size > 1024 * 1024 * 1024 ||
        url !=
            Uri.https(
              'github.com',
              '/openai/codex/releases/download/rust-v$version/codex-package-$target.tar.gz',
            )) {
      throw const FormatException(
        'Invalid official Codex installation package.',
      );
    }
  }

  factory CodexInstallRelease.fromJson(
    Map<String, dynamic> json,
    String target,
  ) {
    final tag = json['tag_name'];
    if (tag is! String ||
        !RegExp(r'^rust-v[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(tag)) {
      throw const FormatException(
        'The official release has no stable version.',
      );
    }
    final name = 'codex-package-$target.tar.gz';
    for (final asset in json['assets'] as List? ?? const []) {
      if (asset is! Map || asset['name'] != name) continue;
      final digest = asset['digest'];
      final size = asset['size'];
      final expected = Uri.https(
        'github.com',
        '/openai/codex/releases/download/$tag/$name',
      );
      if (asset['browser_download_url'] != '$expected' ||
          digest is! String ||
          !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
          size is! int ||
          size <= 0 ||
          size > 1024 * 1024 * 1024) {
        throw const FormatException(
          'The official package has invalid download or integrity metadata.',
        );
      }
      return CodexInstallRelease(
        version: tag.substring(6),
        target: target,
        url: expected,
        sha256: digest.substring(7).toLowerCase(),
        size: size,
      );
    }
    throw FormatException('No complete official Codex package for $target.');
  }
}

/// Explicit user-triggered operation. It never changes settings or PATH.
abstract interface class CodexInstaller {
  bool get supported;
  String get directory;
  Future<CodexInstallRelease> latest();
  Future<String> install(
    CodexInstallRelease release,
    void Function(String) progress,
  );
}

CodexInstaller createCodexInstaller() => platform.createCodexInstaller();
