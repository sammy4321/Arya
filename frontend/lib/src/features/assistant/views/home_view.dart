import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/widgets/assistant_menu_row.dart';
import 'package:flutter/material.dart';

/// The home screen showing the assistant menu options.
class HomeView extends StatelessWidget {
  const HomeView({
    required this.onViewSelected,
    super.key,
  });

  final ValueChanged<AssistantView> onViewSelected;

  static const List<_MenuItemData> _menuItems = [
    _MenuItemData(
      icon: Icons.chat_bubble,
      title: 'Chat',
      subtitle: 'Ask me anything',
      view: AssistantView.chat,
    ),
    _MenuItemData(
      icon: Icons.bolt,
      title: 'Take Action',
      subtitle: 'Automate this task',
      view: AssistantView.takeAction,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF373E47),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          for (final item in _menuItems)
            AssistantMenuRow(
              icon: item.icon,
              title: item.title,
              subtitle: item.subtitle,
              onTap: () => onViewSelected(item.view),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _MenuItemData {
  const _MenuItemData({
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
