/// Local, deliberately conservative checks used only to stop automatic sends.
/// This is not a complete sensitive-data classifier and never calls a model.
/// Native password/protected-field rejection remains a separate requirement.
bool translationNeedsReview(String text) =>
    _reviewPatterns.any((pattern) => pattern.hasMatch(text));

final _reviewPatterns = <RegExp>[
  RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  RegExp(
    r'\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|AKIA[A-Z0-9]{16})\b',
  ),
  RegExp(
    r'\b(?:password|passwd|secret|api[_ -]?key|access[_ -]?token|authorization|bearer|recovery[_ -]?(?:code|seed))\b\s*[:= ]\s*\S+',
    caseSensitive: false,
  ),
  RegExp(r'\b\d{3}[- ]\d{2}[- ]\d{4}\b|\b(?:\d[ -]?){8,}\d\b'),
  RegExp(
    r'\b(?:my|patient|personal)\b.{0,48}\b(?:diagnosis|medication|prescription|medical|balance|savings|account|passport)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(?:ssn|social security|passport number|account number|routing number|credit card|private key)\b',
    caseSensitive: false,
  ),
  RegExp(r'密码|口令|密钥|验证码|恢复码|身份证|护照号|银行卡|银行账号|账户余额|我的病|病历|诊断结果|处方|未成年人'),
  RegExp(r'\b[A-Za-z0-9_+/=-]{48,}\b'),
];
