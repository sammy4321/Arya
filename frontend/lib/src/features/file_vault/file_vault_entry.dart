class FileVaultEntry {
  const FileVaultEntry({
    required this.id,
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.addedAt,
  });

  final int id;
  final String path;
  final String name;
  final int sizeBytes;
  final DateTime addedAt;

  factory FileVaultEntry.fromMap(Map<String, Object?> map) {
    return FileVaultEntry(
      id: (map['id'] as num).toInt(),
      path: map['path'] as String,
      name: map['name'] as String,
      sizeBytes: (map['size_bytes'] as num?)?.toInt() ?? 0,
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['added_at'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
