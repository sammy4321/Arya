import 'dart:io';

import 'package:arya_app/src/core/app_database.dart';
import 'package:arya_app/src/features/file_vault/file_vault_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FileVaultStore {
  FileVaultStore._();

  static final FileVaultStore instance = FileVaultStore._();
  Database? _database;

  Future<Database> _db() async {
    if (_database != null) {
      return _database!;
    }
    _database = await AppDatabase.instance.open();
    return _database!;
  }

  Future<List<FileVaultEntry>> listEntries() async {
    final db = await _db();
    final rows = await db.query('file_vault_entries', orderBy: 'added_at DESC');
    return rows.map(FileVaultEntry.fromMap).toList();
  }

  Future<void> addPaths(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }
    final db = await _db();
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final filePath in paths) {
      final normalized = filePath.trim();
      if (normalized.isEmpty) {
        continue;
      }
      final file = File(normalized);
      if (!await file.exists()) {
        continue;
      }
      final stat = await file.stat();
      batch.insert('file_vault_entries', {
        'path': normalized,
        'name': p.basename(normalized),
        'size_bytes': stat.size,
        'added_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  Future<void> deleteById(int id) async {
    final db = await _db();
    await db.delete('file_vault_entries', where: 'id = ?', whereArgs: [id]);
  }
}
