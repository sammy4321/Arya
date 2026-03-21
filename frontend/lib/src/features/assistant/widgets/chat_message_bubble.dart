import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/widgets/attachment_strip.dart';
import 'package:arya_app/src/features/assistant/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// A user message bubble (left-aligned, blue background).
class UserMessageBubble extends StatelessWidget {
  const UserMessageBubble({required this.message, super.key});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1F80E9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.attachments.isNotEmpty) ...[
              MessageAttachmentDisplay(attachments: message.attachments),
              if (message.content.isNotEmpty) const SizedBox(height: 6),
            ],
            if (message.content.isNotEmpty)
              Text(
                message.content,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }
}

/// An assistant message bubble (right-aligned, gray background).
/// Includes copy button and latency display below the bubble.
class AssistantMessageBubble extends StatelessWidget {
  const AssistantMessageBubble({required this.message, super.key});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF4E5661),
                borderRadius: BorderRadius.circular(12),
              ),
              child: MarkdownBody(
                data: message.content,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(color: Color(0xFFE8E9EB), fontSize: 14),
                  h1: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  h2: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  h3: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  strong: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontWeight: FontWeight.bold,
                  ),
                  em: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontStyle: FontStyle.italic,
                  ),
                  code: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF2E343D),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  blockquoteDecoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Color(0xFF1F80E9), width: 3),
                    ),
                  ),
                  listBullet: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontSize: 14,
                  ),
                ),
                selectable: true,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.latencyMs != null)
                  Text(
                    message.latencyMs! >= 1000
                        ? '${(message.latencyMs! / 1000).toStringAsFixed(1)}s'
                        : '${message.latencyMs}ms',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                if (message.latencyMs != null) const SizedBox(width: 12),
                CopyButton(
                  textToCopy: message.content,
                  iconColor: Colors.white,
                  copiedIconColor: Colors.white,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
