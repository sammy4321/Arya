import 'dart:convert';

import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/services/ai_validation.dart';
import 'package:arya_app/src/features/assistant/services/chat_orchestrator.dart';
import 'package:arya_app/src/features/settings/ai_settings_store.dart';
import 'package:pdfrx/pdfrx.dart';

/// Service for handling AI chat — calls the local ChatOrchestrator directly.
class AiService {
  AiService._();

  static final AiService instance = AiService._();

  final ChatOrchestrator _orchestrator = ChatOrchestrator();

  Future<({String content, int latencyMs})> sendChatMessage(
    List<ChatMessage> messages,
  ) async {
    final store = AiSettingsStore.instance;
    final openRouterKey = await store.getApiKey();
    final tavilyKey = await store.getTavilyApiKey();
    final model = await store.getModel();

    final configIssue = getOpenRouterConfigIssue(
      apiKey: openRouterKey,
      model: model,
    );
    if (configIssue == OpenRouterConfigIssue.missingModel) {
      throw const AiException(
        'Please select a model before sending a message.',
      );
    }
    if (configIssue == OpenRouterConfigIssue.missingApiKey) {
      throw const AiException(
        'OpenRouter API key is missing. Set it in Settings.',
      );
    }

    final formattedMessages = await Future.wait(
      messages.map((m) => _formatMessage(m)),
    );

    final result = await _orchestrator.respond(
      openRouterKey: openRouterKey,
      tavilyKey: tavilyKey,
      model: model,
      webMode: 'auto',
      messages: formattedMessages,
    );

    if (result.content.isEmpty) {
      throw const AiException('No response from AI');
    }

    return (content: result.content, latencyMs: result.latencyMs);
  }

  Stream<AiStreamChunk> streamChatMessage(List<ChatMessage> messages) async* {
    final store = AiSettingsStore.instance;
    final openRouterKey = await store.getApiKey();
    final tavilyKey = await store.getTavilyApiKey();
    final model = await store.getModel();

    final configIssue = getOpenRouterConfigIssue(
      apiKey: openRouterKey,
      model: model,
    );
    if (configIssue == OpenRouterConfigIssue.missingModel) {
      throw const AiException(
        'Please select a model before sending a message.',
      );
    }
    if (configIssue == OpenRouterConfigIssue.missingApiKey) {
      throw const AiException(
        'OpenRouter API key is missing. Set it in Settings.',
      );
    }

    final formattedMessages = await Future.wait(
      messages.map((m) => _formatMessage(m)),
    );

    await for (final chunk in _orchestrator.respondStream(
      openRouterKey: openRouterKey,
      tavilyKey: tavilyKey,
      model: model,
      webMode: 'auto',
      messages: formattedMessages,
    )) {
      yield AiStreamChunk(
        contentDelta: chunk.contentDelta,
        reasoningDelta: chunk.reasoningDelta,
      );
    }
  }

  Future<Map<String, dynamic>> _formatMessage(ChatMessage message) async {
    if (message.attachments.isEmpty) {
      return {
        'role': message.isUser ? 'user' : 'assistant',
        'content': message.content,
      };
    }

    final contentParts = <Map<String, dynamic>>[];

    for (final attachment in message.attachments) {
      if (attachment.isImage) {
        contentParts.add(await _formatImageAttachment(attachment));
      } else if (attachment.name.toLowerCase().endsWith('.pdf')) {
        contentParts.add(await _formatPdfAttachment(attachment));
      } else {
        contentParts.add(_formatTextFileAttachment(attachment));
      }
    }

    if (message.content.isNotEmpty) {
      contentParts.add({'type': 'text', 'text': message.content});
    }

    return {
      'role': message.isUser ? 'user' : 'assistant',
      'content': contentParts,
    };
  }

  Future<Map<String, dynamic>> _formatImageAttachment(
    ChatAttachment attachment,
  ) async {
    final ext = attachment.name.split('.').last.toLowerCase();
    final mimeType = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/png',
    };

    return {
      'type': 'image_url',
      'image_url': {
        'url': 'data:$mimeType;base64,${base64Encode(attachment.bytes)}',
      },
    };
  }

  Future<Map<String, dynamic>> _formatPdfAttachment(
    ChatAttachment attachment,
  ) async {
    String pdfText;
    try {
      final doc = await PdfDocument.openData(attachment.bytes);
      final buffer = StringBuffer();
      for (final page in doc.pages) {
        final pageText = await page.loadText();
        buffer.writeln(pageText.fullText);
      }
      await doc.dispose();
      pdfText = buffer.toString().trim();
      if (pdfText.isEmpty) {
        pdfText = '[PDF contained no extractable text]';
      }
    } catch (e) {
      pdfText = '[Could not extract PDF text: $e]';
    }

    return {'type': 'text', 'text': 'File: ${attachment.name}\n\n$pdfText'};
  }

  Map<String, dynamic> _formatTextFileAttachment(ChatAttachment attachment) {
    String fileText;
    try {
      fileText = utf8.decode(attachment.bytes);
    } catch (_) {
      fileText = '[Could not decode file content]';
    }

    return {'type': 'text', 'text': 'File: ${attachment.name}\n\n$fileText'};
  }
}

class AiException implements Exception {
  const AiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AiStreamChunk {
  const AiStreamChunk({this.contentDelta = '', this.reasoningDelta = ''});

  final String contentDelta;
  final String reasoningDelta;
}
