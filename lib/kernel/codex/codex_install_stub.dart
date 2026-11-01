import 'codex_install.dart';

CodexInstaller createCodexInstaller() => _UnsupportedInstaller();

class _UnsupportedInstaller implements CodexInstaller {
  @override
  bool get supported => false;
  @override
  String get directory => '';
  @override
  Future<CodexInstallRelease> latest() async =>
      throw UnsupportedError('Use the desktop app.');
  @override
  Future<String> install(
    CodexInstallRelease release,
    void Function(String) progress,
  ) async => throw UnsupportedError('Use the desktop app.');
}
