import 'package:flutter/material.dart';

/// The "Learn from Me" view for teaching Arya.
/// This is a placeholder for future implementation.
class LearnFromMeView extends StatelessWidget {
  const LearnFromMeView({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF373E47),
      child: const Center(
        child: Text(
          'Learn from Me - Coming Soon',
          style: TextStyle(
            color: Color(0xFF9EA5AF),
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
