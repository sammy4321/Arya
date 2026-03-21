import 'dart:convert';

import 'package:http/http.dart' as http;

class OpenRouterStreamChunk {
  const OpenRouterStreamChunk({this.contentDelta = '', this.reasoningDelta = ''});

  final String contentDelta;
  final String reasoningDelta;
}

/// Direct Dart client for the OpenRouter chat completions API.
class OpenRouterClient {
  static const _baseUrl = 'https://openrouter.ai/api/v1/chat/completions';

  Future<String> chatCompletion({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final response = await http
        .post(
          Uri.parse(_baseUrl),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'model': model, 'messages': messages}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw OpenRouterException(response.statusCode, response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = payload['choices'] as List<dynamic>? ?? [];
    if (choices.isEmpty) return '';
    final message =
        (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>? ?? {};
    return (message['content'] as String?) ?? '';
  }

  Stream<OpenRouterStreamChunk> chatCompletionStream({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async* {
    final client = http.Client();
    try {
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
        if (delta is! Map<String, dynamic>) continue;

        final contentDelta = _extractDeltaText(
          delta['content'] ?? delta['text'],
        );
        final reasoningDelta = _extractDeltaText(
          delta['reasoning'] ??
              delta['reasoning_content'] ??
              delta['reasoning_text'],
        );
        if (contentDelta.isEmpty && reasoningDelta.isEmpty) continue;
        yield OpenRouterStreamChunk(
          contentDelta: contentDelta,
          reasoningDelta: reasoningDelta,
        );
      }
    } finally {
      client.close();
    }
  }

  static String _extractDeltaText(dynamic raw) {
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
