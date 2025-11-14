import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// PÁGINAS
import 'pages/splash_page.dart';
import 'pages/login_page.dart';
import 'pages/register_page.dart';
import 'pages/conversas_page.dart';
import 'pages/chat_page.dart';
import 'pages/search_page.dart';
import 'pages/profile_page.dart'; // ✅ IMPORT CORRETO

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://ebuybhhxytldczejyxey.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVidXliaGh4eXRsZGN6ZWp5eGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjIzNjYxOTEsImV4cCI6MjA3Nzk0MjE5MX0.gxH22LTNmPEWWOs5n9BsPBFxdFX8dHP6C8NUyQRt5J4',
  );

  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Chat App',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blue,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashPage(),
        '/login': (context) => const LoginPage(),
        '/register': (context) => const RegisterPage(),
        '/home': (context) => const ConversasPage(),
        '/chat': (context) => const ChatPage(),
        '/search': (context) => const SearchPage(),
        '/profile': (context) => const ProfilePage(), // ✅ AGORA FUNCIONA
      },
    );
  }
}
