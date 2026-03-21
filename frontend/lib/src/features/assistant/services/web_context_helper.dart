import 'package:arya_app/src/features/assistant/services/tavily_client.dart';

const List<String> chatAutoWebHints = [
  'latest',
  'today',
  'current',
  'news',
  'recent',
  'as of',
  'this week',
  'this month',
  '2025',
  '2026',
  'price',
  'release date',
  'version',
  'breaking',
];

const List<String> plannerAutoWebHints = [
  'latest',
  'today',
  'current',
  'recent',
  'new',
  'version',
  'news',
];

bool shouldRunWebSearch({
  required String mode,
  required String tavilyKey,
  required String queryText,
  required List<String> autoHints,
}) {
  if (mode == 'never') return false;
  if (mode == 'always') {
    return tavilyKey.trim().isNotEmpty && queryText.trim().isNotEmpty;
  }
  if (tavilyKey.trim().isEmpty || queryText.trim().isEmpty) return false;
  final lower = queryText.toLowerCase();
  return autoHints.any(lower.contains);
}

String formatTavilyResultsContext({
  required List<TavilyResult> results,
  required String intro,
}) {
  final lines = <String>[];
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    lines.add('[${i + 1}] ${r.title}\nURL: ${r.url}\nSnippet: ${r.snippet}');
  }
  return '$intro\n\n${lines.join('\n\n')}';
}
