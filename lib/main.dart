import 'package:flutter/material.dart';
import 'screens/join_class_screen.dart';
import 'utils/constants.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VanishClassNetworkApp());
}

class VanishClassNetworkApp extends StatelessWidget {
  const VanishClassNetworkApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF1E3A8A); // Deep University Blue / Indigo

    return MaterialApp(
      title: AppConstants.appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const JoinClassScreen(),
    );
  }
}
