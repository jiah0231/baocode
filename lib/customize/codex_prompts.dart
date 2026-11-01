import 'customizations.dart';
import 'codex_customization_store.dart';

/// BaoCode prompt commands: text expansion, never executable shell templates.
/// Project prompts override same-named user prompts. Built-ins/native skills
/// take precedence in the caller. These are not server-side slash commands.
class CodexPrompt {
  const CodexPrompt(this.name, this.description, this.body);
  final String name;
  final String description;
  final String body;

  String expand(String arguments) =>
      body.replaceAllMapped(RegExp(r'\$ARGUMENTS\b'), (_) => arguments);

  static Future<List<CodexPrompt>> load(
    CodexCustomizationStore store, {
    String? project,
  }) async {
    final prompts = <String, CodexPrompt>{};
    for (final item in await store.list(
      CustomizationKind.commands,
      project: project,
    )) {
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(item.name)) {
        continue;
      }
      final text = await store.read(item.path);
      prompts[item.name] = CodexPrompt(
        item.name,
        item.description,
        bodyOf(text),
      );
    }
    return prompts.values.toList();
  }

  static List<CodexPrompt> available(
    Iterable<CodexPrompt> prompts,
    Set<String> reserved,
  ) => prompts.where((prompt) => !reserved.contains(prompt.name)).toList();

  static String expandInput(String text, List<CodexPrompt> prompts) {
    final match = RegExp(
      r'^/([a-zA-Z0-9][a-zA-Z0-9_-]{0,63})(?:\s+([\s\S]*))?$',
    ).firstMatch(text);
    if (match == null) return text;
    for (final prompt in prompts) {
      if (prompt.name == match[1]) return prompt.expand(match[2] ?? '');
    }
    return text;
  }
}
