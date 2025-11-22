import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pages/splash_page.dart';
import 'pages/login_page.dart';
import 'pages/register_page.dart';
import 'pages/conversas_page.dart';
import 'pages/chat_page.dart';
import 'pages/search_page.dart';
import 'pages/profile_page.dart';

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

final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updatePresence(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    switch (state) {
      case AppLifecycleState.resumed:
        PresenceService.setOnline(userId);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
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
    // Cores baseadas no WhatsApp
    const waTeal = Color(0xFF008069);
    const waDarkBackground = Color(0xFF121B22); 
    const waChatBackground = Color(0xFF0B141A); 
    const waBubbleGreen = Color(0xFF005C4B);    
    const waBubbleGrey = Color(0xFF1F2C34);     
    const waFabColor = Color(0xFF00A884);       

    return MaterialApp(
      title: 'ChatApp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: waDarkBackground,
        primaryColor: waTeal,
        appBarTheme: const AppBarTheme(
          backgroundColor: waChatBackground,
          elevation: 0,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: waFabColor,
          foregroundColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: waBubbleGrey,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          hintStyle: const TextStyle(color: Colors.grey),
        ),
        colorScheme: const ColorScheme.dark(
          primary: waTeal,
          secondary: waFabColor,
          surface: waChatBackground,
          onSurface: Colors.white,
        ).copyWith(
          tertiary: waBubbleGreen, 
          surfaceContainerHighest: waBubbleGrey,
        ),
      ),
      navigatorObservers: [routeObserver],
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