import 'dart:convert';

import 'package:arya_app/src/core/app_database.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local-only settings store. All keys are persisted in a sqflite DB on disk.
/// No backend server needed.
class AiSettingsStore {
  AiSettingsStore._();

  static final AiSettingsStore instance = AiSettingsStore._();
  Database? _database;

  Future<Database> _db() async {
    if (_database != null) return _database!;
    _database = await AppDatabase.instance.open();
    return _database!;
  }

  Future<String> _get(String key) async {
    final db = await _db();
    final rows = await db.query(
      'ai_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return '';
    return rows.first['value'] as String? ?? '';
  }

  Future<void> _set(String key, String value) async {
    final db = await _db();
    await db.insert(
      'ai_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --- API Keys (stored locally) ---

  Future<String> getApiKey() => _get('openrouter_api_key');
  Future<void> setApiKey(String value) => _set('openrouter_api_key', value.trim());

  Future<String> getTavilyApiKey() => _get('tavily_api_key');
  Future<void> setTavilyApiKey(String value) => _set('tavily_api_key', value.trim());

  // --- Model selection ---

  Future<String> getModel() => _get('openrouter_model');
  Future<void> setModel(String value) => _set('openrouter_model', value.trim());

  // Optional model overrides for planner sub-stages.
  // If unset, each stage falls back to the main selected model.
  Future<String> getDecompositionModel() async {
    final value = await _get('openrouter_model_decomposition');
    return value.isNotEmpty ? value : await getModel();
  }

  Future<String> getCompletionModel() async {
    final value = await _get('openrouter_model_completion');
    return value.isNotEmpty ? value : await getModel();
  }

  Future<String> getPlanningModel() async {
    final value = await _get('openrouter_model_planning');
    return value.isNotEmpty ? value : await getModel();
  }

  // --- Model listing (direct OpenRouter API call) ---

  Future<List<OpenRouterModel>> fetchModels() async {
    final response = await http
        .get(Uri.parse('https://openrouter.ai/api/v1/models'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch models (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>? ?? [];
    final models = <OpenRouterModel>[];
    for (final item in data) {
      if (item is Map<String, dynamic>) {
        final id = item['id'] as String? ?? '';
        final name = item['name'] as String? ?? id;
        if (id.isNotEmpty) {
          models.add(OpenRouterModel(id: id, name: name));
        }
      }
    }
    models.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return models;
  }
}

class OpenRouterModel {
  const OpenRouterModel({required this.id, required this.name});

  final String id;
  final String name;
}
