import 'dart:convert';

import 'package:arya_app/src/features/assistant/models/ai_provider.dart';
import 'package:arya_app/src/features/assistant/services/llm_types.dart';
import 'package:http/http.dart' as http;

class OllamaClient {
  static const defaultBaseUrl = 'http://127.0.0.1:11434';

  /// Ollama `think` option: `true`/`false` for most models; `low`/`medium`/`high`
  /// for GPT-OSS (booleans are ignored for that family).
  /// See: https://docs.ollama.com/capabilities/thinking
  static dynamic _thinkRequestValue(String model, bool includeReasoning) {
    if (!includeReasoning) return null;
    if (model.toLowerCase().contains('gpt-oss')) {
      return 'medium';
    }
    return true;
  }

  static String _stringThinkingField(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v is String) return v;
    if (v != null) return v.toString();
    return '';
  }

  Future<List<AiModelOption>> listModels({String baseUrl = defaultBaseUrl}) async {
    final response = await http
        .get(Uri.parse('${_normalizeBaseUrl(baseUrl)}/api/tags'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw OllamaException(response.statusCode, response.body);
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = payload['models'] as List<dynamic>? ?? const [];
    final models = <AiModelOption>[];
    for (final item in data.whereType<Map<String, dynamic>>()) {
      final id =
          (item['model'] as String?)?.trim() ?? (item['name'] as String?)?.trim() ?? '';
      final name = (item['name'] as String?)?.trim() ?? id;
      if (id.isNotEmpty) {
        models.add(AiModelOption(id: id, name: name));
      }
    }
    models.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return models;
  }

  Future<String> chatCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    String baseUrl = defaultBaseUrl,
  }) async {
    final completion = await chatCompletionDetailed(
      model: model,
      messages: messages,
      baseUrl: baseUrl,
    );
    return completion.content;
  }

  Future<LlmCompletion> chatCompletionDetailed({
    required String model,
    required List<Map<String, dynamic>> messages,
    String baseUrl = defaultBaseUrl,
    bool includeReasoning = false,
  }) async {
    final think = _thinkRequestValue(model, includeReasoning);
    final response = await http
        .post(
          Uri.parse('${_normalizeBaseUrl(baseUrl)}/api/chat'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'messages': _normalizeMessages(messages),
            'stream': false,
            if (think != null) 'think': think,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw OllamaException(response.statusCode, response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final message = payload['message'] as Map<String, dynamic>? ?? const {};
    final reasoningFromMessage = _stringThinkingField(message, 'thinking');
    final reasoningTop = _stringThinkingField(payload, 'thinking');
    return LlmCompletion(
      content: (message['content'] as String? ?? '').trim(),
      reasoning: (reasoningFromMessage.isNotEmpty ? reasoningFromMessage : reasoningTop)
          .trim(),
    );
  }

  Stream<LlmStreamChunk> chatCompletionStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    String baseUrl = defaultBaseUrl,
    /// When true, sends `think` so Ollama emits `message.thinking` chunks.
    bool includeReasoning = true,
  }) async* {
    final client = http.Client();
    try {
      final streamBody = <String, dynamic>{
        'model': model,
        'messages': _normalizeMessages(messages),
        'stream': true,
      };
      final think = _thinkRequestValue(model, includeReasoning);
      if (think != null) {
        streamBody['think'] = think;
      }
      final request = http.Request(
        'POST',
        Uri.parse('${_normalizeBaseUrl(baseUrl)}/api/chat'),
      )
        ..headers.addAll(const {'Content-Type': 'application/json'})
        ..body = jsonEncode(streamBody);

      final response = await client.send(request).timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw OllamaException(response.statusCode, body);
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        Map<String, dynamic> payload;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map<String, dynamic>) continue;
          payload = decoded;
        } catch (_) {
          continue;
        }

        final message = payload['message'] as Map<String, dynamic>? ?? const {};
        final contentDelta = (message['content'] as String? ?? '');
        // Ollama documents reasoning on `message.thinking` for /api/chat (not top-level).
        final fromMessage = _stringThinkingField(message, 'thinking');
        final reasoningDelta =
            fromMessage.isNotEmpty ? fromMessage : _stringThinkingField(payload, 'thinking');
        if (contentDelta.isEmpty && reasoningDelta.isEmpty) continue;
        yield LlmStreamChunk(
          contentDelta: contentDelta,
          reasoningDelta: reasoningDelta,
        );
      }
    } finally {
      client.close();
    }
  }

  List<Map<String, dynamic>> _normalizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return [
      for (final message in messages)
        {
          'role': message['role'] ?? 'user',
          ..._normalizeContent(message['content']),
        },
    ];
  }

  Map<String, dynamic> _normalizeContent(dynamic content) {
    if (content is String) {
      return {'content': content};
    }

    if (content is List) {
      final textParts = <String>[];
      final images = <String>[];
      for (final part in content.whereType<Map<String, dynamic>>()) {
        final type = part['type'];
        if (type == 'text') {
          final text = part['text'] as String? ?? '';
          if (text.isNotEmpty) textParts.add(text);
        } else if (type == 'image_url') {
          final imageUrl = part['image_url'];
          if (imageUrl is Map<String, dynamic>) {
            final url = imageUrl['url'] as String? ?? '';
            final commaIndex = url.indexOf(',');
            if (commaIndex >= 0 && commaIndex + 1 < url.length) {
              images.add(url.substring(commaIndex + 1));
            }
          }
        }
      }
      return {
        'content': textParts.join('\n').trim(),
        if (images.isNotEmpty) 'images': images,
      };
    }

    return {'content': content?.toString() ?? ''};
  }

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) return defaultBaseUrl;
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
}

class OllamaException implements Exception {
  const OllamaException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'Ollama $statusCode: $body';
}
