Future<Map<String, Object?>> readLocations() async => {};
Future<void> writeLocations(Map<String, Object?> value) async =>
    throw UnsupportedError('Session relocation requires local app storage');
