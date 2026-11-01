import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import 'codex_install.dart';

CodexInstaller createCodexInstaller() => IoCodexInstaller(
  directory: p.join(DataDirectory.current.path, 'codex', 'releases'),
  target: switch (Abi.current()) {
    Abi.windowsX64 => 'x86_64-pc-windows-msvc',
    Abi.windowsArm64 => 'aarch64-pc-windows-msvc',
    Abi.macosX64 => 'x86_64-apple-darwin',
    Abi.macosArm64 => 'aarch64-apple-darwin',
    Abi.linuxX64 => 'x86_64-unknown-linux-musl',
    Abi.linuxArm64 => 'aarch64-unknown-linux-musl',
    _ => null,
  },
);

abstract interface class CodexPackageSource {
  Future<Map<String, dynamic>> latest();
  Future<void> download(
    CodexInstallRelease release,
    File file,
    void Function(String) progress,
  );
}

abstract interface class CodexPackageTools {
  Future<void> extract(File archive, Directory destination);
  Future<String> version(String executable);
}

/// Installs beside existing versions; failed updates never replace the old CLI.
/// Settings are changed only by the UI after this returns a verified path.
class IoCodexInstaller implements CodexInstaller {
  IoCodexInstaller({
    required this.directory,
    required this.target,
    CodexPackageSource? source,
    CodexPackageTools? tools,
  }) : source = source ?? HttpCodexPackageSource(),
       tools = tools ?? SystemCodexPackageTools();
  @override
  final String directory;
  final String? target;
  final CodexPackageSource source;
  final CodexPackageTools tools;
  static final Set<String> _installing = {};
  @override
  bool get supported => target != null;
  @override
  Future<CodexInstallRelease> latest() async {
    if (target == null) {
      throw UnsupportedError('This platform has no supported Codex package.');
    }
    return CodexInstallRelease.fromJson(await source.latest(), target!);
  }

  @override
  Future<String> install(
    CodexInstallRelease release,
    void Function(String) progress,
  ) async {
    if (target == null || release.target != target) {
      throw StateError('The package does not match this machine.');
    }
    release.validate();
    if (!_installing.add(directory)) {
      throw StateError('A Codex installation is already running.');
    }
    Directory? staging;
    try {
      await Directory(directory).create(recursive: true);
      staging = await Directory(directory).createTemp('.staging-');
      final archive = File(p.join(staging.path, 'package.tar.gz'));
      progress('Downloading ${release.version}…');
      await source.download(release, archive, progress);
      if (await archive.length() != release.size ||
          '${await crypto.sha256.bind(archive.openRead()).first}' !=
              release.sha256) {
        throw const FormatException(
          'Codex package size or SHA-256 verification failed.',
        );
      }
      progress('Verifying and extracting…');
      final package = await Directory(p.join(staging.path, 'package')).create();
      await tools.extract(archive, package);
      // Same complete-package layout as OpenAI's scripts/install/install.ps1.
      final windows = target!.contains('windows');
      final exe = windows ? 'codex.exe' : 'codex';
      final required = <String>[
        'codex-package.json',
        'bin/$exe',
        if (windows) ...[
          'bin/codex-code-mode-host.exe',
          'codex-path/rg.exe',
          'codex-resources/codex-command-runner.exe',
          'codex-resources/codex-windows-sandbox-setup.exe',
        ],
      ];
      for (final name in required) {
        if (!await File(p.join(package.path, name)).exists()) {
          throw FormatException('Incomplete Codex package: missing $name.');
        }
      }
      final manifest = await File(p.join(package.path, 'codex-package.json'))
          .readAsString();
      if (windows &&
          manifest.contains('"execServer"') &&
          !await File(p.join(package.path, 'bin', 'codex-exec-server.exe'))
              .exists()) {
        throw const FormatException(
          'Incomplete Codex package: missing exec server.',
        );
      }
      progress('Checking installed version…');
      final executable = p.join(package.path, 'bin', exe);
      final version = (await tools.version(executable)).trim();
      if (!RegExp('(?:^|\\s)${RegExp.escape(release.version)}\$')
          .hasMatch(version)) {
        throw FormatException(
          'Installed Codex reported $version, expected ${release.version}.',
        );
      }
      // Unique release folders also allow reinstalling a version while a session
      // still runs the older copy (Windows locks running executables).
      final suffix = p.basename(staging.path).substring('.staging-'.length);
      final destination = p.join(
        directory,
        '${release.version}-$target-$suffix',
      );
      await package.rename(destination);
      return p.join(destination, 'bin', exe);
    } finally {
      try {
        if (staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } finally {
        _installing.remove(directory);
      }
    }
  }
}

class HttpCodexPackageSource implements CodexPackageSource {
  static const _timeout = Duration(seconds: 30);
  static const _hosts = {
    'api.github.com',
    'github.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };
  Future<HttpClientResponse> _get(HttpClient client, Uri url) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (url.scheme != 'https' ||
          !_hosts.contains(url.host) ||
          url.userInfo.isNotEmpty) {
        throw const HttpException('Untrusted Codex download destination.');
      }
      final request = await client.getUrl(url).timeout(_timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_timeout);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(_timeout);
        if (location == null) {
          throw const HttpException('Download redirect has no location.');
        }
        url = url.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(_timeout);
        throw HttpException(
          'Codex download returned HTTP ${response.statusCode}.',
        );
      }
      return response;
    }
    throw const HttpException('Too many Codex download redirects.');
  }

  @override
  Future<Map<String, dynamic>> latest() async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = 'BaoCode';
    try {
      final response = await _get(
        client,
        Uri.https('api.github.com', '/repos/openai/codex/releases/latest'),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw const FormatException('Release metadata is too large.');
        }
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> download(
    CodexInstallRelease release,
    File file,
    void Function(String) progress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = 'BaoCode';
    final sink = file.openWrite();
    try {
      final response = await _get(client, release.url);
      var received = 0;
      var lastPercent = -1;
      await for (final chunk in response.timeout(_timeout)) {
        received += chunk.length;
        if (received > release.size) {
          throw const FormatException(
            'Codex download exceeds its declared size.',
          );
        }
        sink.add(chunk);
        final percent = received * 100 ~/ release.size;
        if (percent != lastPercent) {
          lastPercent = percent;
          progress('Downloading ${release.version}: $percent%');
        }
      }
      await sink.flush();
    } finally {
      try {
        await sink.close();
      } finally {
        client.close(force: true);
      }
    }
  }
}

class SystemCodexPackageTools implements CodexPackageTools {
  static String get _tar => Platform.isWindows
      ? p.join(
          Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'System32',
          'tar.exe',
        )
      : '/usr/bin/tar';

  /// Both GNU tar and Windows' bsdtar print file modes first with -tv.
  /// Permit only files/directories; archive links could escape the staging dir.
  static void validateEntries(String names, String details) {
    for (final line in const LineSplitter().convert(names)) {
      final name = line.replaceAll('\\', '/');
      if (name.startsWith('/') ||
          name.contains(':') ||
          name.split('/').contains('..')) {
        throw const FormatException('Unsafe path in Codex archive.');
      }
    }
    for (final line in const LineSplitter().convert(details)) {
      if (line.isNotEmpty && !line.startsWith('-') && !line.startsWith('d')) {
        throw const FormatException(
          'Links or special files in Codex archive are not supported.',
        );
      }
    }
  }

  static Future<String> _run(String executable, List<String> arguments) async {
    final process = await Process.start(executable, arguments);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final results = await Future.wait<Object>([
        process.exitCode,
        output,
        errors,
      ]).timeout(const Duration(minutes: 2));
      if (results[0] != 0) {
        throw ProcessException(
          executable,
          arguments,
          '${results[2]}',
          results[0] as int,
        );
      }
      return results[1] as String;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  @override
  Future<void> extract(File archive, Directory destination) async {
    final names = await _run(_tar, ['-tzf', archive.path]);
    final details = await _run(_tar, ['-tvzf', archive.path]);
    validateEntries(names, details);
    await _run(_tar, ['-xzf', archive.path, '-C', destination.path]);
    await for (final entity in destination.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link || !p.isWithin(destination.path, entity.path)) {
        throw const FormatException('Unsafe extracted Codex package.');
      }
    }
  }

  @override
  Future<String> version(String executable) => _run(executable, ['--version']);
}
