import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:chat_app/main.dart';
import 'package:chat_app/services/profile_cache.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _nameController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _carregarPerfil();
  }

  Future<void> _carregarPerfil() async {
    final userId = supabase.auth.currentUser!.id;
    final profile = await supabase
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();

    if (profile != null) {
      _nameController.text = profile['name'] ?? '';
    }
    setState(() {});
  }

  Future<void> _salvarNome() async {
    try {
      final userId = supabase.auth.currentUser!.id;

      await supabase.from('profiles').update({
        'name': _nameController.text.trim(),
      }).eq('id', userId);

      /// Atualiza cache
      ProfileCache.setProfile(userId, {
        'name': _nameController.text.trim(),
        'avatar_url': (await supabase
                .from('profiles')
                .select('avatar_url')
                .eq('id', userId)
                .maybeSingle())?['avatar_url'],
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nome atualizado com sucesso!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao atualizar nome: $e')),
      );
    }
  }

  Future<void> _trocarAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );

    if (picked == null) return;

    try {
      setState(() => _isLoading = true);

      final fileBytes = await picked.readAsBytes();
      final fileName = picked.name;

      /// 1️⃣ PEDIR URL ASSINADA PARA SUBIR AVATAR
      final res = await http.post(
        Uri.parse(
          "https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload",
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': fileName,
          'mime': 'image/jpeg',
          'folder': 'avatars', // AQUI É O IMPORTANTE
        }),
      );

      if (res.statusCode != 200) {
        throw "Erro ao gerar URL de upload (${res.statusCode})";
      }

      final data = jsonDecode(res.body);
      final uploadUrl = data['uploadUrl'];
      final key = data['key'];

      /// 2️⃣ FAZER UPLOAD DA IMAGEM
      final uploadRes = await http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'image/jpeg'},
        body: fileBytes,
      );

      if (uploadRes.statusCode != 200 && uploadRes.statusCode != 201) {
        throw "Erro ao enviar imagem (${uploadRes.statusCode})";
      }

      /// 3️⃣ URL PÚBLICA FINAL
      final avatarUrl =
          "https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/avatars/$key";

      /// 4️⃣ ATUALIZAR PERFIL NO SUPABASE
      final userId = supabase.auth.currentUser!.id;
      await supabase.from('profiles').update({
        'avatar_url': avatarUrl,
      }).eq('id', userId);

      /// 5️⃣ ATUALIZAR CACHE
      ProfileCache.setProfile(userId, {
        'name': _nameController.text.trim(),
        'avatar_url': avatarUrl,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Avatar atualizado!'),
            backgroundColor: Colors.green,
          ),
        );
      }

      setState(() {}); // refaz build para exibir novo avatar
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Erro ao trocar avatar: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }

    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final userId = supabase.auth.currentUser!.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meu Perfil'),
      ),
      body: FutureBuilder(
        future: supabase
            .from('profiles')
            .select('name, avatar_url')
            .eq('id', userId)
            .maybeSingle(),
        builder: (context, snapshot) {
          final data = snapshot.data ?? {};
          final avatar = data['avatar_url'];

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 55,
                      backgroundImage:
                          avatar != null ? NetworkImage(avatar) : null,
                      child: avatar == null
                          ? Text(
                              data['name'] != null
                                  ? data['name'][0].toUpperCase()
                                  : "?",
                              style: const TextStyle(fontSize: 40),
                            )
                          : null,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: FloatingActionButton(
                        mini: true,
                        onPressed: _isLoading ? null : _trocarAvatar,
                        child: _isLoading
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Icon(Icons.edit),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),

              // CAMPO NOME
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Nome',
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: _salvarNome,
                child: const Text("Salvar mudanças"),
              ),
            ],
          );
        },
      ),
    );
  }
}
