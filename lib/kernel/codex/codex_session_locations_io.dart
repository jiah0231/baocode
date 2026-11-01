import 'dart:convert';
import 'dart:io';

import '../../platform/data_dir.dart';
import '../../extensions/window/json_state_store.dart' show writeAtomically;

File get _file =>
    File('${DataDirectory.current.stateDir}/codex-session-locations.json');

Future<Map<String, Object?>> readLocations() async {
  final file = _file;
  if (!await file.exists()) return {};
  final value = jsonDecode(await file.readAsString());
  if (value is! Map || value['version'] != 1 || value['sessions'] is! Map) {
    throw const FormatException('Invalid Codex session locations');
  }
  return (value['sessions'] as Map).cast<String, Object?>();
}

Future<void> writeLocations(Map<String, Object?> value) async {
  final file = _file;
  await file.parent.create(recursive: true);
  await writeAtomically(
    file.path,
    jsonEncode({'version': 1, 'sessions': value}),
  );
}
