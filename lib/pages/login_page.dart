import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chat_app/main.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  // Cores Roxas
  final Color purpleBg = const Color(0xFF120D16);
  final Color purpleInput = const Color(0xFF1E1624);
  final Color purpleAccent = const Color(0xFF9D46FF);

  Future<void> _signIn() async {
    setState(() { _isLoading = true; });
    try {
      await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/home');
      }

    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message), backgroundColor: Colors.red));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Erro inesperado.'), backgroundColor: Colors.red));
      }
    }
    setState(() { _isLoading = false; });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: purpleBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo Roxa (Ícone Telefone)
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: purpleAccent.withOpacity(0.1),
                  border: Border.all(color: purpleAccent, width: 2),
                ),
                child: Icon(Icons.phone_in_talk, size: 60, color: purpleAccent),
              ),
              
              const SizedBox(height: 40),

              // NOME CORRIGIDO AQUI:
              const Text(
                'Bem-vindo ao ChatApp',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              
              const SizedBox(height: 10),
              
              const Text(
                'Conecte-se com seus amigos com estilo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),

              const SizedBox(height: 40),

              _buildTextField(
                controller: _emailController,
                label: 'E-mail',
                icon: Icons.email_outlined,
              ),
              
              const SizedBox(height: 16),
              
              _buildTextField(
                controller: _passwordController,
                label: 'Senha',
                icon: Icons.lock_outline,
                isObscure: true,
              ),

              const SizedBox(height: 30),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _signIn,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: purpleAccent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                  ),
                  child: _isLoading 
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('ENTRAR', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),

              const SizedBox(height: 20),

              TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/register'),
                child: RichText(
                  text: TextSpan(
                    text: 'Não tem conta? ',
                    style: const TextStyle(color: Colors.grey),
                    children: [
                      TextSpan(text: 'Cadastre-se', style: TextStyle(color: purpleAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({required TextEditingController controller, required String label, required IconData icon, bool isObscure = false}) {
    return Container(
      decoration: BoxDecoration(
        color: purpleInput,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: controller,
        obscureText: isObscure,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.grey),
          prefixIcon: Icon(icon, color: purpleAccent),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
    );
  }
}