import 'package:arya_app/src/features/assistant/assistant_floating_screen.dart';
import 'package:flutter/material.dart';

class AryaApp extends StatelessWidget {
  const AryaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arya',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      color: Colors.transparent,
      builder: (context, child) => ColoredBox(
        color: Colors.transparent,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const FloatingButtonScreen(),
    );
  }
}
