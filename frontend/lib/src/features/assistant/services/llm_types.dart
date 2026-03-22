class LlmStreamChunk {
  const LlmStreamChunk({this.contentDelta = '', this.reasoningDelta = ''});

  final String contentDelta;
  final String reasoningDelta;
}

class LlmCompletion {
  const LlmCompletion({this.content = '', this.reasoning = ''});

  final String content;
  final String reasoning;
}
