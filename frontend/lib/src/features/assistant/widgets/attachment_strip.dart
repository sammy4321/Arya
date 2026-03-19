import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:flutter/material.dart';

/// Horizontal strip showing pending attachments with remove buttons.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    required this.attachments,
    required this.onRemove,
    super.key,
  });

  final List<ChatAttachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: attachments.asMap().entries.map((entry) {
            final index = entry.key;
            final attachment = entry.value;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF4E5661),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      attachment.name,
                      style: const TextStyle(
                        color: Color(0xFFD2D8DF),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => onRemove(index),
                      child: const Icon(
                        Icons.close,
                        size: 12,
                        color: Color(0xFF9EA5AF),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// Displays attachments within a chat message bubble.
class MessageAttachmentDisplay extends StatelessWidget {
  const MessageAttachmentDisplay({
    required this.attachments,
    super.key,
  });

  final List<ChatAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: attachments.map((a) {
        if (a.isImage) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              a.bytes,
              width: 120,
              height: 120,
              fit: BoxFit.cover,
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.insert_drive_file_outlined,
                size: 13,
                color: Colors.white,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  a.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
