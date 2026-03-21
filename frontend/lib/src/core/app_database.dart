import 'dart:io';

import 'package:arya_app/src/core/app_constants.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  Database? _database;

  Future<Database> open() async {
    if (_database != null) {
      return _database!;
    }

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final dbPath = await getDatabasePath();
    _database = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await _createSchema(db);
        },
      ),
    );
    await _ensureSchema(_database!);
    await _migrateLegacyDatabases(_database!);
    return _database!;
  }

  Future<Directory> resolveSupportDir() async {
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

  Future<String> getDatabasePath() async {
    final supportDir = await resolveSupportDir();
    return p.join(supportDir.path, appDatabaseName);
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_vault_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS internal_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> _ensureSchema(Database db) async {
    await _createSchema(db);
    await db.execute('DROP INDEX IF EXISTS idx_strategy_app_pattern');
    await db.execute('DROP TABLE IF EXISTS strategy_cache');
  }

  Future<void> _migrateLegacyDatabases(Database db) async {
    const migrationKey = 'legacy_split_db_migration_v1';
    final existing = await db.query(
      'internal_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [migrationKey],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return;
    }

    final supportDir = await resolveSupportDir();
    await _migrateLegacyAiSettings(
      db,
      p.join(supportDir.path, legacyAiSettingsDbName),
    );
    await _migrateLegacyFileVault(
      db,
      p.join(supportDir.path, legacyFileVaultDbName),
    );

    await db.insert('internal_metadata', {
      'key': migrationKey,
      'value': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _migrateLegacyAiSettings(Database db, String legacyPath) async {
    final file = File(legacyPath);
    if (!await file.exists()) {
      return;
    }

    final legacyDb = await databaseFactory.openDatabase(legacyPath);
    try {
      final rows = await legacyDb.query('ai_settings');
      for (final row in rows) {
        await db.insert('ai_settings', {
          'key': row['key'],
          'value': row['value'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {
      // Ignore legacy migration failures and keep the unified DB usable.
    } finally {
      await legacyDb.close();
    }
  }

  Future<void> _migrateLegacyFileVault(Database db, String legacyPath) async {
    final file = File(legacyPath);
    if (!await file.exists()) {
      return;
    }

    final legacyDb = await databaseFactory.openDatabase(legacyPath);
    try {
      final rows = await legacyDb.query('file_vault_entries');
      for (final row in rows) {
        await db.insert('file_vault_entries', {
          if (row['id'] != null) 'id': row['id'],
          'path': row['path'],
          'name': row['name'],
          'size_bytes': row['size_bytes'] ?? 0,
          'added_at': row['added_at'] ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {
      // Ignore legacy migration failures and keep the unified DB usable.
    } finally {
      await legacyDb.close();
    }
  }

}
