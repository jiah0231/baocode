import '../l10n/l10n.dart';
import 'translation_service.dart';

extension TranslationStrings on AppLocalizations {
  bool get _zh => localeName.startsWith('zh');
  String get translationTitle => _zh ? '翻译' : 'Translate';
  String get translationSource => _zh ? '原文' : 'Source';
  String get translationResult => _zh ? '译文' : 'Translation';
  String get translationPlaceholder =>
      _zh ? '选择文字后打开，或在这里输入…' : 'Select text before opening, or type here…';
  String get translationWaiting => _zh
      ? '点击「翻译」后，译文将显示在这里。'
      : 'Your translation appears here after you click Translate.';
  String get translationPrivacy => _zh
      ? '仅点击翻译时发送原文。不附带文件或对话，不保存翻译历史。'
      : 'Only Translate sends this text. No files or conversation are included; no translation history is saved.';
  String get translationModel => _zh ? '模型设置' : 'Model settings';
  String get translationModelHint =>
      _zh ? '使用「$modelsQuickAsk」' : 'Uses the Quick Ask model';
  String get translationCopy => _zh ? '复制译文' : 'Copy translation';
  String get translationCopied => _zh ? '已复制' : 'Copied';
  String get translationCopyFailed => _zh
      ? '复制失败，请手动选择译文复制。'
      : 'Could not copy. Select the translation to copy manually.';
  String get translationClose => _zh ? '关闭' : 'Close';
  String get translationCancel => _zh ? '取消' : 'Cancel';
  String get translationRetry => _zh ? '重试' : 'Retry';
  String get translationWorking => _zh ? '正在翻译…' : 'Translating…';
  String get translationSwap => _zh ? '交换语言' : 'Swap languages';
  String get translationNoSelection => _zh
      ? '未取得选中文字，请在下方输入或粘贴。'
      : 'No selected text was captured. Type or paste below.';
  String translationLanguage(String code) => switch (code) {
    'auto' => _zh ? '自动检测' : 'Detect language',
    'zh' => '中文',
    'en' => 'English',
    'ja' => '日本語',
    'ko' => '한국어',
    'fr' => 'Français',
    'de' => 'Deutsch',
    'es' => 'Español',
    _ => code,
  };
  String translationError(TranslationFailure failure) => switch (failure) {
    TranslationFailure.emptySource =>
      _zh ? '请先输入要翻译的文字。' : 'Enter text to translate first.',
    TranslationFailure.sourceTooLong =>
      _zh
          ? '原文不能超过 8,000 字符，请缩短后重试。'
          : 'Source exceeds 8,000 characters. Shorten it and retry.',
    TranslationFailure.noModel =>
      _zh
          ? '请在模型设置中配置可用的「$modelsQuickAsk」。'
          : 'Configure an available Quick Ask model in Model settings.',
    TranslationFailure.timeout =>
      _zh ? '翻译超时，请重试。' : 'Translation timed out. Please retry.',
    TranslationFailure.answerTooLong =>
      _zh
          ? '译文超过长度限制，请分段翻译。'
          : 'Translation exceeds the output limit. Translate smaller sections.',
    TranslationFailure.emptyAnswer =>
      _zh ? '模型未返回译文，请重试。' : 'The model returned no translation. Please retry.',
    TranslationFailure.invalidLanguage =>
      _zh ? '请选择有效的目标语言。' : 'Choose a valid target language.',
    TranslationFailure.requestFailed =>
      _zh
          ? '翻译失败，请检查模型连接后重试。'
          : 'Translation failed. Check the model connection and retry.',
  };
}
