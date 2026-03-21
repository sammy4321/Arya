import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A single strategic approach for accomplishing a task in a given app.
class StrategyApproach {
  const StrategyApproach({
    required this.approach,
    required this.confidence,
  });

  final String approach;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'approach': approach,
    'confidence': confidence,
  };

  factory StrategyApproach.fromJson(Map<String, dynamic> json) {
    return StrategyApproach(
      approach: json['approach'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// A cached strategy entry — keyed by (app, task_pattern).
class StrategyCacheEntry {
  const StrategyCacheEntry({
    required this.appName,
    required this.taskPattern,
    required this.approaches,
    required this.createdAt,
    required this.lastUsedAt,
    required this.useCount,
    required this.failCount,
  });

  final String appName;
  final String taskPattern;
  final List<StrategyApproach> approaches;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final int useCount;
  final int failCount;

  StrategyCacheEntry copyWith({
    DateTime? lastUsedAt,
    int? useCount,
    int? failCount,
    List<StrategyApproach>? approaches,
  }) {
    return StrategyCacheEntry(
      appName: appName,
      taskPattern: taskPattern,
      approaches: approaches ?? this.approaches,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      useCount: useCount ?? this.useCount,
      failCount: failCount ?? this.failCount,
    );
  }

  /// The best approach, factoring in original confidence minus failure penalty.
  StrategyApproach? get bestApproach {
    if (approaches.isEmpty) return null;
    final penalty = failCount * 0.15;
    final scored = approaches.map((a) {
      return (approach: a, score: a.confidence - penalty);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final top = scored.first;
    if (top.score < 0.2) return null;
    return top.approach;
  }

  bool get isExpired {
    const ttl = Duration(days: 7);
    return DateTime.now().difference(createdAt) > ttl;
  }

  bool get isReliable => failCount <= 2 && !isExpired;
}

/// SQLite-backed cache for task strategies, keyed by (app_name, task_pattern).
class StrategyCache {
  StrategyCache._();

  static final StrategyCache instance = StrategyCache._();
  Database? _database;

  Future<Database> _db() async {
    if (_database != null) return _database!;

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final supportDir = await _resolveSupportDir();
    final dbPath = p.join(supportDir.path, 'arya_strategy_cache.db');
    _database = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE strategy_cache (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              app_name TEXT NOT NULL,
              task_pattern TEXT NOT NULL,
              approaches TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              last_used_at INTEGER NOT NULL,
              use_count INTEGER NOT NULL DEFAULT 0,
              fail_count INTEGER NOT NULL DEFAULT 0,
              UNIQUE(app_name, task_pattern)
            )
          ''');
          await db.execute('''
            CREATE INDEX idx_strategy_app_pattern
            ON strategy_cache (app_name, task_pattern)
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

  /// Look up a cached strategy for the given app + task pattern.
  /// Returns null on miss or expired/unreliable entries.
  Future<StrategyCacheEntry?> lookup({
    required String appName,
    required String taskPattern,
  }) async {
    final db = await _db();
    final key = _normalizeKey(appName);
    final pattern = taskPattern.trim().toLowerCase();

    final rows = await db.query(
      'strategy_cache',
      where: 'app_name = ? AND task_pattern = ?',
      whereArgs: [key, pattern],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final entry = _rowToEntry(rows.first);
    if (!entry.isReliable) {
      await _deleteEntry(db, key, pattern);
      return null;
    }
    return entry;
  }

  /// Store a new strategy (or replace existing) for the given app + pattern.
  Future<void> store({
    required String appName,
    required String taskPattern,
    required List<StrategyApproach> approaches,
  }) async {
    if (approaches.isEmpty) return;
    final db = await _db();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'strategy_cache',
      {
        'app_name': _normalizeKey(appName),
        'task_pattern': taskPattern.trim().toLowerCase(),
        'approaches': jsonEncode(approaches.map((a) => a.toJson()).toList()),
        'created_at': now,
        'last_used_at': now,
        'use_count': 1,
        'fail_count': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Record a successful use — bumps use_count and last_used_at.
  Future<void> recordSuccess({
    required String appName,
    required String taskPattern,
  }) async {
    final db = await _db();
    await db.rawUpdate(
      '''UPDATE strategy_cache
         SET use_count = use_count + 1, last_used_at = ?
         WHERE app_name = ? AND task_pattern = ?''',
      [
        DateTime.now().millisecondsSinceEpoch,
        _normalizeKey(appName),
        taskPattern.trim().toLowerCase(),
      ],
    );
  }

  /// Record a failure — bumps fail_count. High fail_count causes eviction
  /// on next lookup.
  Future<void> recordFailure({
    required String appName,
    required String taskPattern,
  }) async {
    final db = await _db();
    await db.rawUpdate(
      '''UPDATE strategy_cache
         SET fail_count = fail_count + 1
         WHERE app_name = ? AND task_pattern = ?''',
      [
        _normalizeKey(appName),
        taskPattern.trim().toLowerCase(),
      ],
    );
  }

  /// Purge all expired entries (older than TTL).
  Future<int> purgeExpired() async {
    final db = await _db();
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 7))
        .millisecondsSinceEpoch;
    return db.delete(
      'strategy_cache',
      where: 'created_at < ?',
      whereArgs: [cutoff],
    );
  }

  Future<void> _deleteEntry(Database db, String appName, String pattern) async {
    await db.delete(
      'strategy_cache',
      where: 'app_name = ? AND task_pattern = ?',
      whereArgs: [appName, pattern],
    );
  }

  StrategyCacheEntry _rowToEntry(Map<String, dynamic> row) {
    final approachesJson = jsonDecode(row['approaches'] as String) as List;
    return StrategyCacheEntry(
      appName: row['app_name'] as String,
      taskPattern: row['task_pattern'] as String,
      approaches: approachesJson
          .whereType<Map<String, dynamic>>()
          .map(StrategyApproach.fromJson)
          .toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      lastUsedAt:
          DateTime.fromMillisecondsSinceEpoch(row['last_used_at'] as int),
      useCount: row['use_count'] as int? ?? 0,
      failCount: row['fail_count'] as int? ?? 0,
    );
  }

  String _normalizeKey(String raw) => raw.trim().toLowerCase();
}
