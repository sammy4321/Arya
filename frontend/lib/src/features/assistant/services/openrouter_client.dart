import 'dart:convert';

import 'package:arya_app/src/features/assistant/services/llm_types.dart';
import 'package:http/http.dart' as http;

/// Direct Dart client for the OpenRouter chat completions API.
class OpenRouterClient {
  static const _baseUrl = 'https://openrouter.ai/api/v1/chat/completions';

  Future<String> chatCompletion({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final completion = await chatCompletionDetailed(
      apiKey: apiKey,
      model: model,
      messages: messages,
      includeReasoning: false,
    );
    return completion.content;
  }

  Future<LlmCompletion> chatCompletionDetailed({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    bool includeReasoning = false,
  }) async {
    final response = await http
        .post(
          Uri.parse(_baseUrl),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': messages,
            if (includeReasoning) 'include_reasoning': true,
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw OpenRouterException(response.statusCode, response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = payload['choices'] as List<dynamic>? ?? [];
    if (choices.isEmpty) return const LlmCompletion();
    final message =
        (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>? ?? {};
    final content = _extractText(message['content'] ?? message['text']);
    final reasoning = _extractText(
      message['reasoning'] ??
          message['reasoning_content'] ??
          message['reasoning_text'],
    );
    return LlmCompletion(content: content, reasoning: reasoning);
  }

  Stream<LlmStreamChunk> chatCompletionStream({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async* {
    final client = http.Client();
    try {
      var lastReasoningSnapshot = '';
      final request = http.Request('POST', Uri.parse(_baseUrl))
        ..headers.addAll({
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'model': model,
          'messages': messages,
          'stream': true,
          // Ask for reasoning tokens when model/provider supports it.
          'include_reasoning': true,
        });

      final response = await client.send(request).timeout(
        const Duration(seconds: 60),
      );

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw OpenRouterException(response.statusCode, body);
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        Map<String, dynamic> payload;
        try {
          final decoded = jsonDecode(data);
          if (decoded is! Map<String, dynamic>) continue;
          payload = decoded;
        } catch (_) {
          continue;
        }

        final choices = payload['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map<String, dynamic>) continue;

        final delta = choice['delta'];
        final deltaMap = delta is Map<String, dynamic> ? delta : const <String, dynamic>{};
        final contentDelta = _extractText(
          deltaMap['content'] ?? deltaMap['text'],
        );

        var reasoningDelta = _extractText(
          deltaMap['reasoning'] ??
              deltaMap['reasoning_content'] ??
              deltaMap['reasoning_text'] ??
              choice['reasoning'] ??
              choice['reasoning_content'] ??
              choice['reasoning_text'] ??
              payload['reasoning'] ??
              payload['reasoning_content'] ??
              payload['reasoning_text'],
        );
        // Some providers stream cumulative reasoning snapshots instead of deltas.
        // Convert snapshots to true deltas to avoid re-appending full text.
        if (reasoningDelta.isNotEmpty) {
          if (reasoningDelta.startsWith(lastReasoningSnapshot)) {
            reasoningDelta = reasoningDelta.substring(lastReasoningSnapshot.length);
            lastReasoningSnapshot = '$lastReasoningSnapshot$reasoningDelta';
          } else {
            lastReasoningSnapshot = '$lastReasoningSnapshot$reasoningDelta';
          }
        }
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

  static String _extractText(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return raw;
    if (raw is List) {
      final buffer = StringBuffer();
      for (final item in raw) {
        if (item is String) {
          buffer.write(item);
          continue;
        }
        if (item is Map<String, dynamic>) {
          final text = item['text'] ?? item['content'];
          if (text is String) {
            buffer.write(text);
          }
        }
      }
      return buffer.toString();
    }
    if (raw is Map<String, dynamic>) {
      final text = raw['text'] ?? raw['content'];
      if (text is String) return text;
    }
    return '';
  }
}

class OpenRouterException implements Exception {
  const OpenRouterException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'OpenRouter $statusCode: $body';
}
