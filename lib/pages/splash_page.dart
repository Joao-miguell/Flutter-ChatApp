import 'package:flutter/material.dart';
import 'package:chat_app/main.dart'; // Importa o 'supabase' global

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  _SplashPageState createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    // Atraso leve para a splash screen ser visível
    await Future.delayed(const Duration(seconds: 1));

    // Verifica a sessão atual
    // O Supabase guarda a sessão automaticamente no dispositivo
    final session = supabase.auth.currentSession;

    if (!mounted) return; // Garante que o widget ainda está na árvore

    if (session == null) {
      // Se não há sessão, vai para a página de Login
      Navigator.of(context).pushReplacementNamed('/login');
    } else {
      // Se há sessão, vai para a página Home
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Um simples indicador de loading
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Bem-vindo ao ChatApp', style: TextStyle(fontSize: 22)),
            SizedBox(height: 20),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}