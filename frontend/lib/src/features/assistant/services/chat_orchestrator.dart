import 'package:arya_app/src/features/assistant/services/openrouter_client.dart';
import 'package:arya_app/src/features/assistant/services/tavily_client.dart';

/// Orchestrates chat responses: optional web search then LLM call.
/// Runs entirely in-process — no backend needed.
class ChatOrchestrator {
  ChatOrchestrator({
    OpenRouterClient? openRouterClient,
    TavilyClient? tavilyClient,
  })  : _openRouter = openRouterClient ?? OpenRouterClient(),
        _tavily = tavilyClient ?? TavilyClient();

  final OpenRouterClient _openRouter;
  final TavilyClient _tavily;

  Future<ChatOrchestratorResult> respond({
    required String openRouterKey,
    required String tavilyKey,
    required String model,
    required String webMode,
    required List<Map<String, dynamic>> messages,
  }) async {
    if (openRouterKey.trim().isEmpty) {
      throw ArgumentError('OpenRouter API key is missing.');
    }
    if (model.trim().isEmpty) {
      throw ArgumentError('Model is required.');
    }

    final stopwatch = Stopwatch()..start();
    var sources = <TavilyResult>[];
    var usedWeb = false;

    final latestUserText = _extractLatestUserText(messages);
    final shouldSearch = _shouldUseWeb(
      mode: webMode,
      latestUserText: latestUserText,
      tavilyKey: tavilyKey,
    );

    var enrichedMessages = List<Map<String, dynamic>>.of(messages);
    if (shouldSearch && latestUserText.isNotEmpty) {
      final webResults = await _tavily.search(
        apiKey: tavilyKey,
        query: latestUserText,
        maxResults: 5,
      );
      if (webResults.isNotEmpty) {
        usedWeb = true;
        sources = webResults.where((r) => r.url.isNotEmpty).toList();
        enrichedMessages = _injectWebContext(messages, webResults);
      }
    }

    final content = await _openRouter.chatCompletion(
      apiKey: openRouterKey,
      model: model,
      messages: enrichedMessages,
    );
    stopwatch.stop();

    return ChatOrchestratorResult(
      content: content,
      latencyMs: stopwatch.elapsedMilliseconds,
      usedWebSearch: usedWeb,
      sources: sources,
    );
  }

  bool _shouldUseWeb({
    required String mode,
    required String latestUserText,
    required String tavilyKey,
  }) {
    if (mode == 'never') return false;
    if (mode == 'always') {
      return tavilyKey.trim().isNotEmpty && latestUserText.trim().isNotEmpty;
    }
    if (tavilyKey.trim().isEmpty || latestUserText.trim().isEmpty) return false;

    final text = latestUserText.toLowerCase();
    const triggers = [
      'latest', 'today', 'current', 'news', 'recent', 'as of',
      'this week', 'this month', '2025', '2026', 'price',
      'release date', 'version', 'breaking',
    ];
    return triggers.any(text.contains);
  }

  static String _extractLatestUserText(List<Map<String, dynamic>> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg['role'] != 'user') continue;
      final content = msg['content'];
      if (content is String) return content;
      if (content is List) {
        final parts = <String>[];
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            final t = part['text'] as String? ?? '';
            if (t.isNotEmpty) parts.add(t);
          }
        }
        return parts.join('\n').trim();
      }
    }
    return '';
  }

  static List<Map<String, dynamic>> _injectWebContext(
    List<Map<String, dynamic>> messages,
    List<TavilyResult> results,
  ) {
    final lines = <String>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      lines.add('[${i + 1}] ${r.title}\nURL: ${r.url}\nSnippet: ${r.snippet}');
    }
    final webContext =
        'Web search results (most relevant first). '
        'Use these as grounding for latest information and cite the URLs when useful.\n\n'
        '${lines.join('\n\n')}';

    return [
      {'role': 'system', 'content': webContext},
      ...messages,
    ];
  }
}

class ChatOrchestratorResult {
  const ChatOrchestratorResult({
    required this.content,
    required this.latencyMs,
    required this.usedWebSearch,
    required this.sources,
  });

  final String content;
  final int latencyMs;
  final bool usedWebSearch;
  final List<TavilyResult> sources;
}
