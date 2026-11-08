import 'package:flutter/widgets.dart';

import '../quick_ask/quick_ask_context.dart';
import 'translation_dialog.dart';

/// Reuses the local selection snapshot; surrounding text and source metadata
/// are deliberately discarded. A clipped selection must never be translated.
Future<void> translateSelection(
  BuildContext context,
  QuickAskContext? source,
) => showTranslationDialog(
  context,
  selectedText: source?.truncated == true ? '' : source?.selectedText ?? '',
  captureStatus: source?.truncated == true ? 'tooLong' : null,
);
