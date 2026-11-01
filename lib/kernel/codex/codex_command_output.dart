import 'dart:async';

/// Keeps all command output, but only publishes a snapshot once per
/// display interval. Search rows are parsed as deltas arrive, not by splitting
/// the entire accumulated output on every notification.
class CodexCommandOutput {
  CodexCommandOutput({
    required this.onChanged,
    this.search = false,
    this.interval = const Duration(milliseconds: 66),
  });

  final void Function() onChanged;
  final bool search;
  final Duration interval;
  final StringBuffer _text = StringBuffer();
  final List<String> _lines = [];
  StringBuffer _line = StringBuffer();
  int _colons = 0;
  bool _hasLine = false;
  bool _dirty = false;
  bool _closed = false;
  Timer? _timer;

  String get text => _text.toString();

  /// Matches the old nonempty-lines, first-two-colon-fields representation,
  /// including the final line while it is still arriving.
  List<String> get matches => [
    ..._lines,
    if (_hasLine) _line.toString(),
  ];

  void add(String delta) {
    if (_closed || delta.isEmpty) return;
    _text.write(delta);
    if (search) {
      for (final unit in delta.codeUnits) {
        if (unit == 10) {
          if (_hasLine) _lines.add(_line.toString());
          _line = StringBuffer();
          _colons = 0;
          _hasLine = false;
        } else {
          _hasLine = true;
          if (unit == 58) _colons++;
          if (_colons < 2) _line.writeCharCode(unit);
        }
      }
    }
    _dirty = true;
    if (_timer == null) _publish();
  }

  void _publish() {
    if (_closed || !_dirty) return;
    _dirty = false;
    // Install before calling out: a listener may finish or dispose the item.
    _timer = Timer(interval, () {
      _timer = null;
      _publish();
    });
    onChanged();
  }

  /// The caller publishes the final snapshot synchronously, with its completed
  /// status. No delayed running snapshot may overwrite it afterwards.
  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
