import 'quick_ask_files.dart';

Future<String> readQuickAskFile(String path) async =>
    throw const QuickAskFileException(QuickAskFileFailure.unreadable);
