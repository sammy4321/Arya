import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/widgets/attachment_strip.dart';
import 'package:arya_app/src/features/assistant/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher_string.dart';

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

  Future<void> _openLink(BuildContext context, String? href) async {
    final url = href?.trim() ?? '';
    if (url.isEmpty) return;
    final launched = await launchUrlString(
      url,
      mode: LaunchMode.externalApplication,
    );
    if (launched) return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open link in browser.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayedContent = message.isStreaming && message.content.isNotEmpty
        ? '${message.content}▍'
        : message.content;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.reasoning.trim().isNotEmpty) ...[
                    _ReasoningPanel(
                      reasoning: message.reasoning,
                      isStreaming: message.isStreaming,
                      isThinking:
                          message.isStreaming && message.content.trim().isEmpty,
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (displayedContent.isNotEmpty)
                    MarkdownBody(
                      data: displayedContent,
                      onTapLink: (_, href, __) => _openLink(context, href),
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
                    )
                  else if (message.isStreaming)
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFB8C1CC),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Generating response...',
                          style: TextStyle(color: Color(0xFFE8E9EB), fontSize: 13),
                        ),
                      ],
                    ),
                ],
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
                if (message.latencyMs != null)
                  const SizedBox(width: 12),
                if (message.content.isNotEmpty)
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

class _ReasoningPanel extends StatefulWidget {
  const _ReasoningPanel({
    required this.reasoning,
    required this.isStreaming,
    required this.isThinking,
  });

  final String reasoning;
  final bool isStreaming;
  final bool isThinking;

  @override
  State<_ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<_ReasoningPanel> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Keep reasoning visible while model is in "thinking" phase.
    _expanded = widget.isThinking;
  }

  @override
  void didUpdateWidget(covariant _ReasoningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isThinking && !_expanded) {
      setState(() => _expanded = true);
      return;
    }
    // As soon as response content starts streaming, collapse reasoning.
    if (!widget.isThinking && oldWidget.isThinking && _expanded) {
      setState(() => _expanded = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF3D454F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF677281)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 15,
                    color: const Color(0xFFD2D8DF),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.psychology_alt_outlined,
                    size: 14,
                    color: Color(0xFFD2D8DF),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Thought process',
                    style: TextStyle(
                      color: Color(0xFFD2D8DF),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.isStreaming) ...[
                    const SizedBox(width: 6),
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: Color(0xFFD2D8DF),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Text(
                widget.reasoning,
                style: const TextStyle(
                  color: Color(0xFFD2D8DF),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
