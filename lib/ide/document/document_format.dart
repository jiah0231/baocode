import 'package:path/path.dart' as p;

/// Read-only formats. Legacy Office files are routed here for a useful error,
/// never passed to the text editor (which could damage their binary contents).
enum DocumentKind { word, presentation, spreadsheet, delimited, legacy }

DocumentKind? documentKindForPath(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.docx' => DocumentKind.word,
      '.pptx' => DocumentKind.presentation,
      '.xlsx' => DocumentKind.spreadsheet,
      '.csv' || '.tsv' => DocumentKind.delimited,
      '.doc' || '.ppt' || '.xls' => DocumentKind.legacy,
      _ => null,
    };

/// Editable delimited text keeps the existing source editor. The parser also
/// accepts CSV/TSV for callers explicitly requesting a data view, but opening
/// those files must not silently remove the user's ability to edit them.
bool ideIsDocumentPath(String path) => switch (documentKindForPath(path)) {
  null || DocumentKind.delimited => false,
  _ => true,
};
