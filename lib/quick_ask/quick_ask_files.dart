import 'package:path/path.dart' as p;

import '../l10n/l10n.dart';
import 'quick_ask_files_stub.dart'
    if (dart.library.io) 'quick_ask_files_io.dart'
    as platform;

/// Explicitly picked, read-only snapshots. Paths stay local; only the name and
/// bounded text are sent. No automatic discovery, persistence or dependencies.
class QuickAskFileContext {
  const QuickAskFileContext({required this.name, required this.text});

  static const maxFiles = 3;
  static const maxCharacters = 8000;
  static const maxBytes = 32000;
  final String name;
  final String text;

  static Future<QuickAskFileContext> read(String path) async =>
      QuickAskFileContext(
        name: p.basename(path),
        text: await platform.readQuickAskFile(path),
      );

  Map<String, String> toJson() => {'name': name, 'text': text};
}

enum QuickAskFileFailure { tooLarge, notText, unreadable }

class QuickAskFileException implements Exception {
  const QuickAskFileException(this.reason);
  final QuickAskFileFailure reason;
}

// Kept with this optional feature, like the workbench's other scoped strings.
// English is the fallback for locales not yet supported by BaoCode.
extension QuickAskFileStrings on AppLocalizations {
  bool get _chinese => localeName.startsWith('zh');
  String get quickAskAddFile => _chinese ? '添加文件…' : 'Add file…';
  String get quickAskFilesHint => _chinese
      ? '仅在发送时附上你选择的磁盘文件快照。最多 3 个 UTF-8 文本文件，每个 8,000 字符；不含未保存的修改。'
      : 'Only send includes these chosen disk snapshots. Up to 3 UTF-8 text files, 8,000 characters each; unsaved edits are not included.';
  String get quickAskFileTooLarge => _chinese
      ? '请选择不超过 8,000 字符的文本文件。未添加此文件。'
      : 'Choose a text file of at most 8,000 characters. This file was not added.';
  String get quickAskFilesPrivacy => _chinese
      ? '仅发送下方已启用的选区、附近上下文和所选文件快照，不读取其他文件或完整历史。'
      : 'Only the enabled selection, nearby context and chosen file snapshots below are sent. No other files or full history are read.';
}
