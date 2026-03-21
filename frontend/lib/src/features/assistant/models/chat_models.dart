import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Available assistant views.
enum AssistantView {
  home,
  chat,
  takeAction,
  settings,
}

/// Represents a file attachment in a chat message.
class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.bytes,
    required this.isImage,
  });

  final String name;
  final Uint8List bytes;
  final bool isImage;
}

/// Represents a single chat message.
class ChatMessage {
  const ChatMessage({
    required this.content,
    required this.isUser,
    this.latencyMs,
    this.reasoning = '',
    this.isStreaming = false,
    this.attachments = const [],
  });

  final String content;
  final bool isUser;

  /// Response latency in milliseconds (for assistant messages only).
  final int? latencyMs;
  final String reasoning;
  final bool isStreaming;

  final List<ChatAttachment> attachments;

  ChatMessage copyWith({
    String? content,
    bool? isUser,
    int? latencyMs,
    bool clearLatency = false,
    String? reasoning,
    bool? isStreaming,
    List<ChatAttachment>? attachments,
  }) {
    return ChatMessage(
      content: content ?? this.content,
      isUser: isUser ?? this.isUser,
      latencyMs: clearLatency ? null : (latencyMs ?? this.latencyMs),
      reasoning: reasoning ?? this.reasoning,
      isStreaming: isStreaming ?? this.isStreaming,
      attachments: attachments ?? this.attachments,
    );
  }
}

/// Menu item displayed on the assistant home screen.
class AssistantMenuItem {
  const AssistantMenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.view,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final AssistantView view;
}
