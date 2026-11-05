import 'dart:typed_data';

import 'package:bao_remote/search.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/file_views.dart';
import 'package:baocode/ide/ide_document_preview.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/workbench/contributions.dart';
import 'package:baocode/ide/workbench/contributions/editor_panes.dart';
import 'package:baocode/ide/workbench/editor_panes.dart';
import 'package:baocode/ide/workbench/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_files.dart';
import 'services/fake_host.dart';

class _RemoteFiles extends TreeFiles implements IdeHostFiles {
  _RemoteFiles() : super({});

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);
  @override
  Stream<void> watchDirectory(String directory) => const Stream.empty();
  @override
  Future<IdeFileListing> listProject(String root, {int limit = 50000}) async =>
      IdeFileListing([]);
  @override
  Stream<Object> searchText(String root, IdeTextQuery query) =>
      const Stream.empty();
}

class _Environment {
  _Environment(IdeFileService files)
    : workspace = IdeWorkspace(testRoot, files: files) {
    services
      ..add<WorkbenchHost>(host)
      ..add(panes)
      ..add(workspace);
    contribution = EditorPanesContribution(services);
    addTearDown(() {
      contribution.dispose();
      services.dispose();
    });
  }

  final services = WorkbenchServices();
  final panes = EditorPaneRegistry();
  final host = FakeWorkbenchHost();
  final IdeWorkspace workspace;
  late final EditorPanesContribution contribution;

  IdeDocument media(String name, {String? view}) {
    final document = IdeDocument.media(inRoot(name), view: view);
    addTearDown(document.dispose);
    return document;
  }

  Future<IdeDocumentPreview> buildPreview(
    WidgetTester tester,
    IdeDocument document,
  ) async {
    late IdeDocumentPreview preview;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          // Inspect the production registry's chosen widget without mounting its
          // renderer. This regression never starts WebView2 or reads a document.
          preview =
              panes.paneFor(document)!.build(context, document)
                  as IdeDocumentPreview;
          return const SizedBox.shrink();
        },
      ),
    );
    return preview;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all twelve NoteBoard formats outrank the image pane after refactoring',
    () {
      final environment = _Environment(TreeFiles({}));
      for (final extension in [
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'pdf',
        'epub',
        'dwg',
        'dxf',
        'note',
        'goodnotes',
      ]) {
        final document = environment.media('REPORT.${extension.toUpperCase()}');
        expect(
          environment.panes.paneFor(document)?.id,
          'workbench.editor.document',
          reason: extension,
        );
      }
      for (final extension in ['png', 'jpg', 'gif', 'webp']) {
        expect(
          environment.panes.paneFor(environment.media('image.$extension'))?.id,
          'workbench.editor.media',
        );
      }
      for (final extension in ['csv', 'tsv', 'txt', 'md', 'dart']) {
        final document = IdeDocument(inRoot('editable.$extension'), 'text');
        addTearDown(document.dispose);
        expect(environment.panes.paneFor(document), isNull);
      }
    },
  );

  test('explicit file views retain priority over document and image panes', () {
    final environment = _Environment(TreeFiles({}));
    const id = 'test.document-pane-explicit-view';
    FileViews.register(
      FileView(id: id, matches: (_) => true, build: (_, _) => const SizedBox()),
    );
    addTearDown(() => FileViews.unregister(id));
    final document = environment.media('example.docx', view: id);
    expect(
      environment.panes.paneFor(document)?.id,
      'workbench.editor.fileView',
    );
  });

  testWidgets(
    'local document pane keeps the original file service and external-open action',
    (tester) async {
      final files = TreeFiles({});
      final environment = _Environment(files);
      final document = environment.media('report.docx');
      final preview = await environment.buildPreview(tester, document);
      expect(preview.files, same(files));
      expect(preview.path, document.path);
      expect(preview.key, ValueKey(document));
      expect(preview.historical, isFalse);
      expect(preview.onOpenInDefaultApp, isNotNull);
      preview.onOpenInDefaultApp!();
      await tester.pump();
      expect(environment.host.calls, ['openInDefaultApp ${document.path}']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'remote document pane cannot open a remote path in a local application',
    (tester) async {
      final files = _RemoteFiles();
      final environment = _Environment(files);
      final preview = await environment.buildPreview(
        tester,
        environment.media('remote.xlsx'),
      );
      expect(preview.files, same(files));
      expect(preview.onOpenInDefaultApp, isNull);
      expect(environment.host.calls, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
