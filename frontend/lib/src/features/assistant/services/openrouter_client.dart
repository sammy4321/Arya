import 'dart:convert';

import 'package:http/http.dart' as http;

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
}

class OpenRouterException implements Exception {
  const OpenRouterException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'OpenRouter $statusCode: $body';
}
