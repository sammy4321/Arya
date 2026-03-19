import 'package:flutter/material.dart';

class PlaceholderSettingsPage extends StatelessWidget {
  const PlaceholderSettingsPage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(color: Color(0xFF9FAABC), fontSize: 13),
    );
  }
}
