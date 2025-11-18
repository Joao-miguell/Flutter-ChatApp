// lib/main.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// PÁGINAS
import 'pages/splash_page.dart';
import 'pages/login_page.dart';
import 'pages/register_page.dart';
import 'pages/conversas_page.dart';
import 'pages/chat_page.dart';
import 'pages/search_page.dart';
import 'pages/profile_page.dart';

// SERVIÇOS (Importante para atualizar o status)
import 'services/presence_service.dart';

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

// 🟢 Mudamos para StatefulWidget para usar WidgetsBindingObserver
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    // Registra este widget para ouvir mudanças no ciclo de vida (abrir/fechar app)
    WidgetsBinding.instance.addObserver(this);
    
    // Se o usuário já estiver logado ao abrir o app, marca como Online
    _updatePresence(true);
  }

  @override
  void dispose() {
    // Remove o observador quando o app é destruído
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 🟢 DETECTA QUANDO O APP É ABERTO, FECHADO OU MINIMIZADO
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    switch (state) {
      case AppLifecycleState.resumed:
        // App voltou para o foco (Online)
        PresenceService.setOnline(userId);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive: // Adicionado para cobrir mais casos
      case AppLifecycleState.hidden:   // Adicionado para cobrir mais casos
        // App foi minimizado ou fechado (Offline)
        PresenceService.setOffline(userId);
        break;
    }
  }

  Future<void> _updatePresence(bool isOnline) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      if (isOnline) {
        await PresenceService.setOnline(userId);
      } else {
        await PresenceService.setOffline(userId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Chat App',
      debugShowCheckedModeBanner: false, // Remove a etiqueta "Debug"
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
        '/profile': (context) => const ProfilePage(),
      },
    );
  }
}