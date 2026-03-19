import 'dart:convert';

import 'package:http/http.dart' as http;

/// Direct Dart client for the Tavily web search API.
class TavilyClient {
  static const _baseUrl = 'https://api.tavily.com/search';

  Future<List<TavilyResult>> search({
    required String apiKey,
    required String query,
    int maxResults = 5,
  }) async {
    if (apiKey.trim().isEmpty || query.trim().isEmpty) return [];

    final response = await http
        .post(
          Uri.parse(_baseUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'api_key': apiKey,
            'query': query,
            'search_depth': 'basic',
            'max_results': maxResults,
            'include_answer': false,
            'include_raw_content': false,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) return [];

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final results = payload['results'] as List<dynamic>? ?? [];
    return results
        .whereType<Map<String, dynamic>>()
        .map(
          (item) => TavilyResult(
            title: (item['title'] as String?) ?? '',
            url: (item['url'] as String?) ?? '',
            snippet: (item['content'] as String?) ?? '',
          ),
        )
        .toList();
  }
}

class TavilyResult {
  const TavilyResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, String> toMap() => {
        'title': title,
        'url': url,
        'snippet': snippet,
      };
}
