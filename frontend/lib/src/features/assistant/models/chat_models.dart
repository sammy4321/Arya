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
    this.attachments = const [],
  });

  final String content;
  final bool isUser;

  /// Response latency in milliseconds (for assistant messages only).
  final int? latencyMs;

  final List<ChatAttachment> attachments;
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
