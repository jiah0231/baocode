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

bool ideIsDocumentPath(String path) => documentKindForPath(path) != null;
