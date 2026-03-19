import 'dart:io';

import 'package:arya_app/src/core/app_constants.dart';
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

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final supportDir = await _resolveSupportDir();
    final dbPath = p.join(supportDir.path, fileVaultDbName);
    _database = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE file_vault_entries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              path TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              size_bytes INTEGER NOT NULL DEFAULT 0,
              added_at INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
    return _database!;
  }

  Future<Directory> _resolveSupportDir() async {
    String basePath;

    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      basePath = home == null
          ? Directory.current.path
          : p.join(home, 'Library', 'Application Support');
    } else if (Platform.isLinux) {
      final xdgData = Platform.environment['XDG_DATA_HOME'];
      if (xdgData != null && xdgData.isNotEmpty) {
        basePath = xdgData;
      } else {
        final home = Platform.environment['HOME'];
        basePath = home == null
            ? Directory.current.path
            : p.join(home, '.local', 'share');
      }
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      final localAppData = Platform.environment['LOCALAPPDATA'];
      basePath = (appData != null && appData.isNotEmpty)
          ? appData
          : ((localAppData != null && localAppData.isNotEmpty)
                ? localAppData
                : Directory.current.path);
    } else {
      basePath = Directory.current.path;
    }

    final dir = Directory(p.join(basePath, 'Arya'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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
