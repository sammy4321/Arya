import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copy button that briefly shows a checkmark on tap (ChatGPT-style feedback).
class CopyButton extends StatefulWidget {
  const CopyButton({
    required this.textToCopy,
    this.iconColor = const Color(0xFF9EA5AF),
    this.copiedIconColor = const Color(0xFF34D399),
    this.size = 14,
    this.tooltip = 'Copy Response',
    super.key,
  });

  final String textToCopy;
  final Color iconColor;
  final Color copiedIconColor;
  final double size;
  final String tooltip;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _copied = false;

  void _onTap() {
    Clipboard.setData(ClipboardData(text: widget.textToCopy));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: InkWell(
        onTap: _onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) {
              return ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                ),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: Icon(
              _copied ? Icons.check : Icons.copy,
              key: ValueKey(_copied),
              size: widget.size,
              color: _copied ? widget.copiedIconColor : widget.iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
