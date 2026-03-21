enum OpenRouterConfigIssue { missingApiKey, missingModel }

OpenRouterConfigIssue? getOpenRouterConfigIssue({
  required String apiKey,
  required String model,
}) {
  if (apiKey.trim().isEmpty) return OpenRouterConfigIssue.missingApiKey;
  if (model.trim().isEmpty) return OpenRouterConfigIssue.missingModel;
  return null;
}

void validateOpenRouterConfig({required String apiKey, required String model}) {
  final issue = getOpenRouterConfigIssue(apiKey: apiKey, model: model);
  if (issue == OpenRouterConfigIssue.missingApiKey) {
    throw ArgumentError('OpenRouter API key is missing.');
  }
  if (issue == OpenRouterConfigIssue.missingModel) {
    throw ArgumentError('Model is required.');
  }
}
