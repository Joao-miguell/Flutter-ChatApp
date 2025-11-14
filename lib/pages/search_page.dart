import 'package:flutter/material.dart';
import 'package:chat_app/main.dart'; // Importa o 'supabase' global

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = false;
  final _searchController = TextEditingController();

  // 🔍 Busca de utilizadores
  Future<void> _searchUsers(String query) async {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final meuUserId = supabase.auth.currentUser!.id;

      final results = await supabase
          .from('profiles')
          .select()
          .like('name', '%$query%')
          .neq('id', meuUserId);

      setState(() {
        _searchResults = results;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro na busca: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    setState(() {
      _isLoading = false;
    });
  }

  // 💬 Cria (ou abre) uma conversa individual
  Future<void> _iniciarConversa(String outroUserId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;

      // 1️⃣ Busca as conversas em que ambos já possam estar
      final existingConversations = await supabase
          .from('participants')
          .select('conversation_id')
          .inFilter('user_id', [meuUserId, outroUserId]); // 🔹 corrigido

      if (existingConversations.isNotEmpty) {
        final conversationIds = existingConversations
            .map((p) => p['conversation_id'])
            .toSet()
            .toList();

        // Verifica se ambos participam da mesma conversa
        final shared = await supabase
            .from('participants')
            .select('conversation_id')
            .inFilter('conversation_id', conversationIds) // 🔹 corrigido
            .eq('user_id', outroUserId);

        if (shared.isNotEmpty) {
          // Já existe conversa
          final conversaId = shared.first['conversation_id'];
          if (mounted) {
            Navigator.of(context)
                .popAndPushNamed('/chat', arguments: conversaId);
          }
          return;
        }
      }

      // 2️⃣ Cria uma nova conversa individual
      final conversaData = await supabase
          .from('conversations')
          .insert({'is_group': false})
          .select()
          .single();

      final conversaId = conversaData['id'];

      // 3️⃣ Adiciona ambos os participantes
      await supabase.from('participants').insert([
        {'conversation_id': conversaId, 'user_id': meuUserId},
        {'conversation_id': conversaId, 'user_id': outroUserId},
      ]);

      // 4️⃣ Navega para o chat
      if (mounted) {
        Navigator.of(context).popAndPushNamed('/chat', arguments: conversaId);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao iniciar conversa: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Buscar utilizadores...',
            border: InputBorder.none,
          ),
          onChanged: _searchUsers,
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final user = _searchResults[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: (user['avatar_url'] != null)
                        ? NetworkImage(user['avatar_url'])
                        : null,
                    child: (user['avatar_url'] == null)
                        ? Text(user['name'][0].toUpperCase())
                        : null,
                  ),
                  title: Text(user['name']),
                  subtitle: Text(
                    user['is_online'] == true ? 'Online' : 'Offline',
                  ),
                  onTap: () => _iniciarConversa(user['id']),
                );
              },
            ),
    );
  }
}
