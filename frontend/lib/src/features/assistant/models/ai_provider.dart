enum AiProvider { openrouter, ollama }

AiProvider aiProviderFromStorage(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'ollama':
      return AiProvider.ollama;
    case 'openrouter':
    default:
      return AiProvider.openrouter;
  }
}

extension AiProviderX on AiProvider {
  String get storageValue => switch (this) {
    AiProvider.openrouter => 'openrouter',
    AiProvider.ollama => 'ollama',
  };

  String get label => switch (this) {
    AiProvider.openrouter => 'OpenRouter',
    AiProvider.ollama => 'Ollama',
  };
}

class AiModelOption {
  const AiModelOption({required this.id, required this.name});

  final String id;
  final String name;
}
