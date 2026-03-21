import 'package:arya_app/src/features/assistant/services/ai_validation.dart';
import 'package:arya_app/src/features/assistant/services/openrouter_client.dart';
import 'package:arya_app/src/features/assistant/services/tavily_client.dart';
import 'package:arya_app/src/features/assistant/services/web_context_helper.dart';

/// Orchestrates chat responses: optional web search then LLM call.
/// Runs entirely in-process — no backend needed.
class ChatOrchestrator {
  ChatOrchestrator({
    OpenRouterClient? openRouterClient,
    TavilyClient? tavilyClient,
  }) : _openRouter = openRouterClient ?? OpenRouterClient(),
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
    validateOpenRouterConfig(apiKey: openRouterKey, model: model);

    final stopwatch = Stopwatch()..start();
    var sources = <TavilyResult>[];
    var usedWeb = false;

    final latestUserText = _extractLatestUserText(messages);
    final shouldSearch = shouldRunWebSearch(
      mode: webMode,
      tavilyKey: tavilyKey,
      queryText: latestUserText,
      autoHints: chatAutoWebHints,
    );
    // Helpful runtime visibility when diagnosing whether web context is used.
    // ignore: avoid_print
    print(
      '[ChatOrchestrator] shouldSearch=$shouldSearch '
      'query="${latestUserText.length > 80 ? '${latestUserText.substring(0, 80)}...' : latestUserText}"',
    );

    var enrichedMessages = List<Map<String, dynamic>>.of(messages);
    if (shouldSearch && latestUserText.isNotEmpty) {
      final webResults = await _tavily.search(
        apiKey: tavilyKey,
        query: latestUserText,
        maxResults: 5,
      );
      // ignore: avoid_print
      print('[ChatOrchestrator] webResults=${webResults.length}');
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

  Stream<ChatOrchestratorStreamChunk> respondStream({
    required String openRouterKey,
    required String tavilyKey,
    required String model,
    required String webMode,
    required List<Map<String, dynamic>> messages,
  }) async* {
    validateOpenRouterConfig(apiKey: openRouterKey, model: model);

    final latestUserText = _extractLatestUserText(messages);
    final shouldSearch = shouldRunWebSearch(
      mode: webMode,
      tavilyKey: tavilyKey,
      queryText: latestUserText,
      autoHints: chatAutoWebHints,
    );
    // ignore: avoid_print
    print(
      '[ChatOrchestrator/stream] shouldSearch=$shouldSearch '
      'query="${latestUserText.length > 80 ? '${latestUserText.substring(0, 80)}...' : latestUserText}"',
    );

    var enrichedMessages = List<Map<String, dynamic>>.of(messages);
    if (shouldSearch && latestUserText.isNotEmpty) {
      final webResults = await _tavily.search(
        apiKey: tavilyKey,
        query: latestUserText,
        maxResults: 5,
      );
      // ignore: avoid_print
      print('[ChatOrchestrator/stream] webResults=${webResults.length}');
      if (webResults.isNotEmpty) {
        enrichedMessages = _injectWebContext(messages, webResults);
      }
    }

    await for (final chunk in _openRouter.chatCompletionStream(
      apiKey: openRouterKey,
      model: model,
      messages: enrichedMessages,
    )) {
      yield ChatOrchestratorStreamChunk(
        contentDelta: chunk.contentDelta,
        reasoningDelta: chunk.reasoningDelta,
      );
    }
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
    final webContext = formatTavilyResultsContext(
      results: results,
      intro:
          'Web search results (most relevant first). '
          'You MUST ground your answer in these results for freshness-sensitive requests '
          '(latest/current/news/today/version/price/recent). '
          'Do not respond with generic advice only. '
          'Include source citations as markdown links using the exact URLs from these results.',
    );

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

class ChatOrchestratorStreamChunk {
  const ChatOrchestratorStreamChunk({
    this.contentDelta = '',
    this.reasoningDelta = '',
  });

  final String contentDelta;
  final String reasoningDelta;
}
