import 'chat_models.dart';

/// Whether [tool] (a step's) is one of the `session_*` tools.
bool isSessionTool(String? tool) => tool != null && tool.startsWith('session_');

/// The conversations a `session_*` step is about, by their ids: the one it
/// started, else those it names.
List<String> sessionIdsOf(ToolCallItem item) => [
  if (item.tool == 'session_new') ?_started.firstMatch(item.output ?? '')?[1],
  if (item.input['session'] case final String id when id.isNotEmpty) id,
  if (item.input['sessions'] case final List<Object?> ids)
    ...ids.whereType<String>(),
];

final _started = RegExp(r'^Started: (\S+)');
