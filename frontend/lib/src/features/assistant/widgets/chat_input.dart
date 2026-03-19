import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/widgets/attachment_strip.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

/// Input field for chat with attachment support and send button.
class ChatInput extends StatelessWidget {
  const ChatInput({
    required this.controller,
    required this.attachments,
    required this.isLoading,
    required this.onSend,
    required this.onAttachmentRemove,
    required this.onPickFile,
    required this.onScreenshot,
    this.isCapturingScreenshot = false,
    super.key,
  });

  final TextEditingController controller;
  final List<ChatAttachment> attachments;
  final bool isLoading;
  final bool isCapturingScreenshot;
  final VoidCallback onSend;
  final ValueChanged<int> onAttachmentRemove;
  final VoidCallback onPickFile;
  final VoidCallback onScreenshot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF4E5661),
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(11),
        ),
      ),
      child: Row(
        children: [
          // Text input field with icons inside
          Expanded(
            child: Container(
              constraints: const BoxConstraints(
                maxHeight: 200,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF373E47),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AttachmentStrip(
                    attachments: attachments,
                    onRemove: onAttachmentRemove,
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Plus icon for file attachment
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Tooltip(
                          message: 'Attach file',
                          child: InkWell(
                            onTap: onPickFile,
                            borderRadius: BorderRadius.circular(8),
                            child: const Icon(
                              Icons.add,
                              color: Color(0xFFD2D8DF),
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                      // Screenshot icon
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Tooltip(
                          message: 'Attach screenshot',
                          child: InkWell(
                            onTap: isCapturingScreenshot ? null : onScreenshot,
                            borderRadius: BorderRadius.circular(8),
                            child: isCapturingScreenshot
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFD2D8DF),
                                    ),
                                  )
                                : const Icon(
                                    Icons.screenshot_monitor,
                                    color: Color(0xFFD2D8DF),
                                    size: 18,
                                  ),
                          ),
                        ),
                      ),
                      // TextField
                      Expanded(
                        child: TextField(
                          controller: controller,
                          style: const TextStyle(
                            color: Color(0xFFE8E9EB),
                            fontSize: 14,
                          ),
                          maxLines: 5,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => isLoading ? null : onSend(),
                          decoration: const InputDecoration(
                            hintText: 'Ask me anything...',
                            hintStyle: TextStyle(
                              color: Color(0xFF9EA5AF),
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            isCollapsed: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Submit/Send icon
          _SendButton(
            isLoading: isLoading,
            onTap: onSend,
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.isLoading,
    required this.onTap,
  });

  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: isLoading
            ? const Color(0xFF677281)
            : const Color(0xFF1F80E9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (!isLoading)
              const Icon(
                Icons.send,
                color: Colors.white,
                size: 18,
              ),
            if (isLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
