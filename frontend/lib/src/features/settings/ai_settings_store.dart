import 'dart:convert';

import 'package:arya_app/src/core/app_database.dart';
import 'package:arya_app/src/features/assistant/models/ai_provider.dart';
import 'package:arya_app/src/features/assistant/services/ollama_client.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local-only settings store. All keys are persisted in a sqflite DB on disk.
/// No backend server needed.
class AiSettingsStore {
  AiSettingsStore._();

  static final AiSettingsStore instance = AiSettingsStore._();
  Database? _database;
  final Map<String, String> _cache = {};

  Future<Database> _db() async {
    if (_database != null) return _database!;
    _database = await AppDatabase.instance.open();
    return _database!;
  }

  Future<String> _get(String key) async {
    final cached = _cache[key];
    if (cached != null) return cached;
    final db = await _db();
    final rows = await db.query(
      'ai_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    final value = rows.isEmpty ? '' : (rows.first['value'] as String? ?? '');
    if (value.isNotEmpty) _cache[key] = value;
    return value;
  }

  Future<void> _set(String key, String value) async {
    final db = await _db();
    await db.insert(
      'ai_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (value.isNotEmpty) {
      _cache[key] = value;
    } else {
      _cache.remove(key);
    }
  }

  // --- API Keys (stored locally) ---

  Future<AiProvider> getProvider() async {
    final raw = await _get('ai_provider');
    return aiProviderFromStorage(raw);
  }

  Future<void> setProvider(AiProvider provider) =>
      _set('ai_provider', provider.storageValue);

  Future<String> getOpenRouterApiKey() => _get('openrouter_api_key');
  Future<void> setOpenRouterApiKey(String value) =>
      _set('openrouter_api_key', value.trim());
  Future<String> getApiKey() => getOpenRouterApiKey();
  Future<void> setApiKey(String value) => setOpenRouterApiKey(value);

  Future<String> getOllamaBaseUrl() async {
    final value = await _get('ollama_base_url');
    return value.isNotEmpty ? value : OllamaClient.defaultBaseUrl;
  }

  Future<void> setOllamaBaseUrl(String value) async {
    final normalized = value.trim().isEmpty
        ? OllamaClient.defaultBaseUrl
        : value.trim();
    await _set('ollama_base_url', normalized);
  }

  Future<String> getTavilyApiKey() => _get('tavily_api_key');
  Future<void> setTavilyApiKey(String value) => _set('tavily_api_key', value.trim());

  // --- Model selection ---

  String _modelKeyFor(AiProvider provider, {String suffix = ''}) =>
      '${provider.storageValue}_model$suffix';

  Future<String> getModel() async {
    final provider = await getProvider();
    return _get(_modelKeyFor(provider));
  }

  Future<void> setModel(String value) async {
    final provider = await getProvider();
    await _set(_modelKeyFor(provider), value.trim());
  }

  // Optional model overrides for planner sub-stages.
  // If unset, each stage falls back to the main selected model.
  Future<String> getDecompositionModel() async {
    final provider = await getProvider();
    final value = await _get(_modelKeyFor(provider, suffix: '_decomposition'));
    return value.isNotEmpty ? value : await getModel();
  }

  Future<String> getCompletionModel() async {
    final provider = await getProvider();
    final value = await _get(_modelKeyFor(provider, suffix: '_completion'));
    return value.isNotEmpty ? value : await getModel();
  }

  Future<String> getPlanningModel() async {
    final provider = await getProvider();
    final value = await _get(_modelKeyFor(provider, suffix: '_planning'));
    return value.isNotEmpty ? value : await getModel();
  }

  // --- Model listing ---

  Future<List<AiModelOption>> fetchAvailableModels() async {
    final provider = await getProvider();
    switch (provider) {
      case AiProvider.openrouter:
        return _fetchOpenRouterModels();
      case AiProvider.ollama:
        return _fetchOllamaModels();
    }
  }

  Future<List<AiModelOption>> _fetchOpenRouterModels() async {
    final response = await http
        .get(Uri.parse('https://openrouter.ai/api/v1/models'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch models (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>? ?? [];
    final models = <AiModelOption>[];
    for (final item in data) {
      if (item is Map<String, dynamic>) {
        final id = item['id'] as String? ?? '';
        final name = item['name'] as String? ?? id;
        if (id.isNotEmpty) {
          models.add(AiModelOption(id: id, name: name));
        }
      }
    }
    models.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return models;
  }

  Future<List<AiModelOption>> _fetchOllamaModels() async {
    final baseUrl = await getOllamaBaseUrl();
    return OllamaClient().listModels(baseUrl: baseUrl);
  }
}
