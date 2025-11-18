// lib/pages/profile_page.dart
import 'dart:async'; // 🟢 Adicionado para Future.delayed (ajuste de UI)
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:chat_app/main.dart';
import 'package:chat_app/services/profile_cache.dart';
import 'package:chat_app/services/presence_service.dart'; // 🟢 Novo Import

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _nameController = TextEditingController();
  bool _isLoading = false; // Usado para nome e avatar
  
  // 🟢 Adicionados para carregar o perfil corretamente ao iniciar
  String? _avatarUrl;
  String? _currentName;
  bool _showOnlineStatus = true; // Necessário para o cache

  @override
  void initState() {
    super.initState();
    _carregarPerfil();
  }

  Future<void> _carregarPerfil() async {
    final userId = supabase.auth.currentUser!.id;
    // Usando o cache para carregar o perfil mais rápido
    final profile = await ProfileCache.getProfile(userId);

    if (profile != null) {
      _currentName = profile['name'] ?? '';
      _avatarUrl = profile['avatar_url'] as String?;
      _showOnlineStatus = profile['show_online_status'] ?? true;
      _nameController.text = _currentName ?? '';
    }
    setState(() {});
  }

  Future<void> _salvarNome() async {
    final userId = supabase.auth.currentUser!.id;
    final newName = _nameController.text.trim();
    if (newName.isEmpty) return;

    try {
      await supabase.from('profiles').update({
        'name': newName,
      }).eq('id', userId);

      /// Atualiza cache
      ProfileCache.setProfile(userId, {
        'name': newName,
        'avatar_url': _avatarUrl,
        'show_online_status': _showOnlineStatus, // 🟢 Mantém o status
      });
      _currentName = newName;

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
  
  // 🟢 Lógica de Salvar Privacidade
  Future<void> _savePrivacySetting(bool value) async {
    final userId = supabase.auth.currentUser!.id;
    try {
      await supabase.from('profiles').update({'show_online_status': value}).eq('id', userId);
      
      // Atualiza o cache e a presença no banco
      ProfileCache.setProfile(userId, {'name': _currentName, 'avatar_url': _avatarUrl, 'show_online_status': value});
      await PresenceService.setOnline(userId); // Força a atualização da presença com a nova regra
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Privacidade atualizada para ${value ? 'Público' : 'Privado'}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao atualizar privacidade: $e')));
    }
  }


  Future<void> _trocarAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 300,
      maxHeight: 300,
    );

    if (picked == null) return;

    try {
      setState(() => _isLoading = true); // Inicia loading

      final fileBytes = await picked.readAsBytes();
      final fileName = 'avatar_${supabase.auth.currentUser!.id}.jpeg';

      /// 1️⃣ PEDIR URL ASSINADA
      final res = await http.post(
        Uri.parse("https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': fileName,
          'mime': 'image/jpeg',
          'folder': 'avatars',
        }),
      );

      if (res.statusCode != 200) throw "Erro ao gerar URL de upload (${res.statusCode})";

      final data = jsonDecode(res.body);
      final uploadUrl = data['uploadUrl'];
      final key = data['key'];

      /// 2️⃣ FAZER UPLOAD DA IMAGEM
      final uploadRes = await http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'image/jpeg'},
        body: fileBytes,
      );

      if (uploadRes.statusCode != 200 && uploadRes.statusCode != 201) throw "Erro ao enviar imagem (${uploadRes.statusCode})";

      /// 3️⃣ URL PÚBLICA FINAL (Adiciona timestamp para forçar recarga)
      final newAvatarUrl = "https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/avatars/$key";
      final finalUrlWithTimestamp = '$newAvatarUrl?t=${DateTime.now().millisecondsSinceEpoch}';

      /// 4️⃣ ATUALIZAR PERFIL NO SUPABASE
      final userId = supabase.auth.currentUser!.id;
      await supabase.from('profiles').update({
        'avatar_url': newAvatarUrl, // Salva a URL limpa no DB
      }).eq('id', userId);

      /// 5️⃣ ATUALIZAR CACHE
      ProfileCache.setProfile(userId, {
        'name': _currentName,
        'avatar_url': newAvatarUrl, // Atualiza o cache com a URL limpa
        'show_online_status': _showOnlineStatus,
      });

      _avatarUrl = newAvatarUrl; // Atualiza o estado local para o build
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Avatar atualizado com sucesso!'), backgroundColor: Colors.green));
      }

      setState(() {}); 
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Erro ao trocar avatar: $e"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() => _isLoading = false); // Termina loading
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Usamos o estado local (_avatarUrl) que é atualizado na função _trocarAvatar
    // para evitar um FutureBuilder complexo no meio do build.

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meu Perfil'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 1. AVATAR PRINCIPAL
                CircleAvatar(
                  radius: 55,
                  // Adiciona timestamp apenas para a exibição no Flutter para forçar recarga
                  backgroundImage: _avatarUrl != null 
                      ? NetworkImage('$_avatarUrl?t=${DateTime.now().millisecondsSinceEpoch}') 
                      : null,
                  child: _avatarUrl == null
                      ? Text(
                          _currentName != null && _currentName!.isNotEmpty
                              ? _currentName![0].toUpperCase()
                              : "?",
                          style: const TextStyle(fontSize: 40),
                        )
                      : null,
                ),
                
                // 2. INDICADOR DE LOADING
                if (_isLoading)
                   const Positioned.fill(
                       child: Center(
                           child: CircularProgressIndicator(),
                       ),
                   ),

                // 3. O BOTÃO LÁPIS (Corrigido para a estética)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: _isLoading ? null : _trocarAvatar, // Desativa se estiver carregando
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor, 
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black, width: 2), 
                      ),
                      child: const Icon(
                        Icons.edit, 
                        size: 18, 
                        color: Colors.white,
                      ),
                    ),
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

          // Botão Salvar Nome
          ElevatedButton(
            onPressed: _salvarNome,
            child: const Text("Salvar Nome"),
          ),
          
          const SizedBox(height: 32),
          
          // SWITCH DE PRIVACIDADE
          SwitchListTile(
            title: const Text('Mostrar Status Online'),
            subtitle: const Text('Se desativado, você sempre aparecerá como "Offline".'),
            value: _showOnlineStatus,
            onChanged: (value) {
              setState(() {
                _showOnlineStatus = value;
              });
              _savePrivacySetting(value);
            },
          ),
        ],
      ),
    );
  }
}