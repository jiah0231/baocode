import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/kernel/codex/codex_install.dart';
import 'package:baocode/kernel/codex/codex_install_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const target = 'x86_64-pc-windows-msvc';
final payload = utf8.encode('verified package fixture');
Map<String, dynamic> metadata() => {
  'tag_name': 'rust-v1.2.3',
  'assets': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'codex-package-$target.tar.gz',
      'browser_download_url':
          'https://github.com/openai/codex/releases/download/rust-v1.2.3/codex-package-$target.tar.gz',
      'digest': 'sha256:${sha256.convert(payload)}',
      'size': payload.length,
    },
  ],
};

class _Source implements CodexPackageSource {
  bool corrupt = false;
  int downloads = 0;
  @override
  Future<Map<String, dynamic>> latest() async => metadata();
  @override
  Future<void> download(
    CodexInstallRelease release,
    File file,
    void Function(String) progress,
  ) async {
    downloads++;
    await file.writeAsBytes(
      corrupt ? [payload.first ^ 1, ...payload.skip(1)] : payload,
    );
  }
}

class _Tools implements CodexPackageTools {
  int extractions = 0;
  int versionChecks = 0;
  String reported = 'codex-cli 1.2.3';
  bool incomplete = false;
  @override
  Future<void> extract(File archive, Directory destination) async {
    extractions++;
    for (final path in [
      'codex-package.json',
      'bin/codex.exe',
      'bin/codex-code-mode-host.exe',
      'codex-path/rg.exe',
      'codex-resources/codex-command-runner.exe',
      if (!incomplete) 'codex-resources/codex-windows-sandbox-setup.exe',
    ]) {
      final file = File(p.join(destination.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsString(path.endsWith('.json') ? '{}' : 'fixture');
    }
  }

  @override
  Future<String> version(String executable) async {
    versionChecks++;
    return reported;
  }
}

/// One small ustar entry, so the platform tar path is exercised without any
/// network download or execution of downloaded software.
List<int> archiveEntry(String name, {String type = '0', String link = ''}) {
  final header = Uint8List(512);
  void field(int offset, int length, String value) {
    final encoded = utf8.encode(value);
    assert(encoded.length <= length);
    header.setRange(offset, offset + encoded.length, encoded);
  }

  field(0, 100, name);
  field(100, 8, '0000644');
  field(108, 8, '0000000');
  field(116, 8, '0000000');
  field(124, 12, type == '0' ? '00000000003' : '00000000000');
  field(136, 12, '00000000000');
  header.fillRange(148, 156, 32);
  field(156, 1, type);
  field(157, 100, link);
  field(257, 6, 'ustar');
  field(263, 2, '00');
  final checksum = header.fold<int>(0, (sum, byte) => sum + byte);
  field(148, 6, checksum.toRadixString(8).padLeft(6, '0'));
  header[154] = 0;
  header[155] = 32;
  return gzip.encode([
    ...header,
    if (type == '0') ...[...utf8.encode('ok!'), ...List.filled(509, 0)],
    ...List.filled(1024, 0),
  ]);
}

void main() {
  test('only complete official stable package with a digest is accepted', () {
    final release = CodexInstallRelease.fromJson(metadata(), target);
    expect(release.version, '1.2.3');
    expect(release.sha256, '${sha256.convert(payload)}');
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (data) => (data['assets'] as List).first['digest'] = null,
      (data) => (data['assets'] as List).first['browser_download_url'] =
          'https://example.com/codex.exe',
      (data) => data['tag_name'] = 'rust-v../../bad',
      (data) => (data['assets'] as List).first['size'] = -1,
      (data) => (data['assets'] as List).first['name'] = 'codex.exe',
    ]) {
      final data = metadata();
      mutate(data);
      expect(
        () => CodexInstallRelease.fromJson(data, target),
        throwsFormatException,
      );
    }
  });

  test(
    'archive entries reject traversal, absolute paths, links and special files',
    () {
      SystemCodexPackageTools.validateEntries(
        './\n./bin/\n./bin/codex.exe\n',
        'drwxr-xr-x folder\n-rwxr-xr-x executable\n',
      );
      for (final name in [
        '../bad',
        '/absolute',
        r'C:\absolute',
        r'bin\..\bad',
      ]) {
        expect(
          () =>
              SystemCodexPackageTools.validateEntries(name, '-rw-r--r-- file'),
          throwsFormatException,
        );
      }
      for (final mode in [
        'lrwxrwxrwx',
        'hrwxrwxrwx',
        'crw-------',
        'prw-------',
      ]) {
        expect(
          () => SystemCodexPackageTools.validateEntries(
            'bin/codex',
            '$mode file',
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'system tar extracts regular files and blocks traversal and links',
    () async {
      final root = Directory.systemTemp.createTempSync('codex-tar-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final tools = SystemCodexPackageTools();
      final archive = File(p.join(root.path, 'fixture.tar.gz'));
      final destination = Directory(p.join(root.path, 'extracted'))
        ..createSync();
      archive.writeAsBytesSync(archiveEntry('normal.txt'));
      await tools.extract(archive, destination);
      expect(
        File(p.join(destination.path, 'normal.txt')).readAsStringSync(),
        'ok!',
      );
      archive.writeAsBytesSync(archiveEntry('../escaped.txt'));
      await expectLater(tools.extract(archive, destination), throwsA(anything));
      expect(File(p.join(root.path, 'escaped.txt')).existsSync(), isFalse);
      archive.writeAsBytesSync(
        archiveEntry('linked', type: '2', link: '../outside'),
      );
      await expectLater(tools.extract(archive, destination), throwsA(anything));
      expect(Link(p.join(destination.path, 'linked')).existsSync(), isFalse);
    },
  );

  group('managed installation', () {
    late Directory root;
    late _Source source;
    late _Tools tools;
    late IoCodexInstaller installer;
    setUp(() {
      root = Directory.systemTemp.createTempSync('codex-install-test-');
      source = _Source();
      tools = _Tools();
      installer = IoCodexInstaller(
        directory: root.path,
        target: target,
        source: source,
        tools: tools,
      );
    });
    tearDown(() => root.deleteSync(recursive: true));

    test(
      'verified install keeps full layout and never replaces older releases',
      () async {
        final old = File(p.join(root.path, 'old', 'codex.exe'));
        old.parent.createSync();
        old.writeAsStringSync('old version');
        final release = await installer.latest();
        final path = await installer.install(release, (_) {});
        expect(File(path).existsSync(), isTrue);
        expect(p.isWithin(root.path, path), isTrue);
        expect(old.readAsStringSync(), 'old version');
        expect(
          File(p.join(p.dirname(p.dirname(path)), 'codex-path', 'rg.exe'))
              .existsSync(),
          isTrue,
        );
        expect(
          root.listSync().where(
            (e) => p.basename(e.path).startsWith('.staging-'),
          ),
          isEmpty,
        );
        final second = await installer.install(release, (_) {});
        expect(second, isNot(path));
        expect(File(path).existsSync(), isTrue);
      },
    );

    test(
      'bad digest is rejected before extraction; staging is cleaned',
      () async {
        source.corrupt = true;
        await expectLater(
          installer.install(await installer.latest(), (_) {}),
          throwsFormatException,
        );
        expect(tools.extractions, 0);
        expect(tools.versionChecks, 0);
        expect(root.listSync(), isEmpty);
      },
    );

    test(
      'incomplete package and wrong reported version cannot be selected',
      () async {
        final release = await installer.latest();
        tools.incomplete = true;
        await expectLater(
          installer.install(release, (_) {}),
          throwsFormatException,
        );
        tools.incomplete = false;
        tools.reported = 'codex-cli 1.2.2';
        await expectLater(
          installer.install(release, (_) {}),
          throwsFormatException,
        );
        expect(root.listSync(), isEmpty);
        // Failed operations release the install lock so retry can work.
        tools.reported = 'codex-cli 1.2.3';
        expect(
          File(await installer.install(release, (_) {})).existsSync(),
          isTrue,
        );
      },
    );

    test('directly constructed unsafe releases fail before download', () async {
      final release = CodexInstallRelease(
        version: '../../outside',
        target: target,
        url: Uri.https('github.com', '/openai/codex/releases/invalid'),
        sha256: '0' * 64,
        size: 1,
      );
      await expectLater(
        installer.install(release, (_) {}),
        throwsFormatException,
      );
      expect(source.downloads, 0);
      expect(root.listSync(), isEmpty);
    });

    test('a package for another machine is never downloaded', () async {
      final release = CodexInstallRelease(
        version: '1.2.3',
        target: 'other',
        url: Uri.https('github.com', '/invalid'),
        sha256: '',
        size: 1,
      );
      await expectLater(installer.install(release, (_) {}), throwsStateError);
      expect(source.downloads, 0);
    });
  });
}
