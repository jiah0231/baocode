import 'package:path/path.dart' as p;

/// Read-only formats. Binary containers never enter the text editor. Windows
/// uses the bundled NoteBoard plugins; other platforms keep explicit fallbacks.
enum DocumentKind {
  word,
  presentation,
  spreadsheet,
  delimited,
  legacy,
  embedded,
}

DocumentKind? documentKindForPath(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.docx' => DocumentKind.word,
      '.pptx' => DocumentKind.presentation,
      '.xlsx' => DocumentKind.spreadsheet,
      '.csv' || '.tsv' => DocumentKind.delimited,
      '.doc' || '.ppt' || '.xls' => DocumentKind.legacy,
      '.pdf' ||
      '.epub' ||
      '.dwg' ||
      '.dxf' ||
      '.note' ||
      '.goodnotes' => DocumentKind.embedded,
      _ => null,
    };

/// Editable delimited text keeps the existing source editor. The parser also
/// accepts CSV/TSV for callers explicitly requesting a data view, but opening
/// those files must not silently remove the user's ability to edit them.
bool ideIsDocumentPath(String path) => switch (documentKindForPath(path)) {
  null || DocumentKind.delimited => false,
  _ => true,
};

/// Exact read-only extension set advertised by the bundled NoteBoard plugins.
/// Text, CSV/TSV, Markdown, source files and images retain BaoCode's editors.
String? nativeDocumentFormat(String path) {
  final extension = p.extension(path).toLowerCase();
  return const {
        '.doc',
        '.docx',
        '.xls',
        '.xlsx',
        '.ppt',
        '.pptx',
        '.pdf',
        '.epub',
        '.dwg',
        '.dxf',
        '.note',
        '.goodnotes',
      }.contains(extension)
      ? extension.substring(1)
      : null;
}
