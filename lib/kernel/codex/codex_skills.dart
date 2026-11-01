import 'package:path/path.dart' as p;

/// A skill advertised by the running Codex server. Paths belong to that
/// server's host; never reinterpret a remote path on this machine.
class CodexSkill {
  const CodexSkill(this.name, this.description, this.path);

  final String name;
  final String description;
  final String path;

  Map<String, Object?> get input => {
    'type': 'skill',
    'name': name,
    'path': path,
  };

  /// Keep server order (and therefore its scope precedence), with only
  /// enabled skills and names that the slash command picker can insert.
  static List<CodexSkill> fromResponse(
    Map<String, Object?> response, {
    required String? cwd,
    p.Context? paths,
    Set<String> reserved = const {'review', 'init', 'diff', 'goal'},
  }) {
    // The caller knows the server host: SSH paths stay POSIX even when
    // BaoCode itself runs on Windows. Do not infer style from this OS.
    final hostPaths = paths ?? p.posix;
    final seen = <String>{...reserved};
    final result = <CodexSkill>[];
    for (final entry in response['data'] as List? ?? const []) {
      if (entry is! Map) continue;
      if (cwd != null) {
        final entryCwd = entry['cwd'];
        if (entryCwd is! String || !hostPaths.equals(entryCwd, cwd)) continue;
      }
      for (final raw in entry['skills'] as List? ?? const []) {
        if (raw is! Map || raw['enabled'] != true) continue;
        final name = raw['name'];
        final path = raw['path'];
        if (name is! String ||
            path is! String ||
            path.isEmpty ||
            !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name) ||
            !seen.add(name)) {
          continue;
        }
        final description = raw['description'] as String? ?? '';
        result.add(CodexSkill(name, description, path));
      }
    }
    return result;
  }

  /// A skill selected explicitly as /name or $name, not a substring of a
  /// sentence. Codex receives a typed skill input, not a made-up prompt.
  static CodexSkill? invoked(String text, List<CodexSkill> skills) {
    final first = text.trimLeft().split(RegExp(r'\s')).first;
    if (!first.startsWith('/') && !first.startsWith(r'$')) return null;
    final name = first.substring(1);
    for (final skill in skills) {
      if (skill.name == name) return skill;
    }
    return null;
  }
}
