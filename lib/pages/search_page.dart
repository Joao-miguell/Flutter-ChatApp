// lib/pages/search_page.dart
import 'package:flutter/material.dart';
import 'package:chat_app/services/supabase_service.dart';
import 'dialogs/create_group_dialog.dart'; // <--- importe o diálogo

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = false;
  final _searchController = TextEditingController();

  Future<void> _searchUsers(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final meuUserId = supabase.auth.currentUser!.id;

      // Busca por users
      final users = await supabase
          .from('profiles')
          .select()
          .ilike('name', '%$query%')
          .neq('id', meuUserId);

      // 🟢 CORREÇÃO: Busca de Grupos 🟢
      // Removi o filtro .eq('is_public', true) para que ele ache
      // até os grupos que foram criados incorretamente como privados.
      final groups = await supabase
          .from('conversations')
          .select('id, name, avatar_url')
          .ilike('name', '%$query%')
          .eq('is_group', true); 

      final results = <Map<String, dynamic>>[];

      if (users != null) {
        for (var u in users) {
          results.add({
            'type': 'user',
            'id': u['id'],
            'name': u['name'],
            'avatar_url': u['avatar_url'],
            'is_online': u['is_online'] ?? false,
          });
        }
      }

      if (groups != null) {
        for (var g in groups) {
          results.add({
            'type': 'group',
            'id': g['id'],
            'name': g['name'] ?? 'Grupo',
            'avatar_url': g['avatar_url'],
          });
        }
      }

      setState(() {
        _searchResults = results;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erro na busca: $error'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Lógica para iniciar conversa privada
  Future<void> _iniciarConversaComUsuario(String outroUserId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;

      // 1. Busca todas as conversas em que EU estou
      final myConversationsResponse = await supabase
          .from('participants')
          .select('conversation_id')
          .eq('user_id', meuUserId);

      final myConversationIds = myConversationsResponse
          .map((p) => p['conversation_id'] as String)
          .toList();

      if (myConversationIds.isNotEmpty) {
        // 2. Dessas, filtra as que o OUTRO usuário está E NÃO SÃO GRUPO
        final sharedPrivateChatResponse = await supabase
            .from('participants')
            .select('conversation_id, conversations!inner(is_group)') // Join
            .inFilter('conversation_id', myConversationIds) 
            .eq('user_id', outroUserId) 
            .eq('conversations.is_group', false)
            .maybeSingle(); 

        if (sharedPrivateChatResponse != null) {
          // 3. Encontrou chat privado, abre ele
          final conversaId = sharedPrivateChatResponse['conversation_id'] as String;
          if (mounted) {
            Navigator.of(context).popAndPushNamed('/chat', arguments: conversaId);
          }
          return;
        }
      }
      // 4. Não encontrou, joga exceção para criar um novo
      throw Exception('Nenhum chat privado encontrado. Criando novo.');
      
    } catch (_) {
      // 5. Bloco de criação
      try {
        final meuUserId = supabase.auth.currentUser!.id;
        final conversaData = await supabase.from('conversations').insert({
          'is_group': false
        }).select().single(); 
        final conversaId = conversaData['id'] as String;

        await supabase.from('participants').insert([
          {'conversation_id': conversaId, 'user_id': meuUserId},
          {'conversation_id': conversaId, 'user_id': outroUserId},
        ]); 

        if (mounted) {
          Navigator.of(context).popAndPushNamed('/chat', arguments: conversaId);
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erro ao iniciar conversa: $error'),
            backgroundColor: Colors.red,
          ));
        }
      }
    }
  }

  // 🟢 CORREÇÃO: Criação de Grupo 🟢
  Future<void> _criarGrupoSimples(String name, List<String> participantIds) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;
      final data = await supabase
          .from('conversations')
          // Agora definimos 'is_public: true' para garantir que apareça na busca futura
          .insert({'is_group': true, 'name': name, 'is_public': true}) 
          .select()
          .single(); 
      final groupId = data['id'] as String;

      final inserts = [
        {'conversation_id': groupId, 'user_id': meuUserId},
      ];
      for (var pid in participantIds) {
        inserts.add({'conversation_id': groupId, 'user_id': pid});
      }
      await supabase.from('participants').insert(inserts); 

      if (mounted) {
        Navigator.of(context).popAndPushNamed('/chat', arguments: groupId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao criar grupo: $e')));
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _buildResultTile(Map<String, dynamic> item) {
    final type = item['type'] as String?;
    final name = item['name'] as String? ?? '...';
    final avatar = item['avatar_url'] as String?;
    final isOnline = item['is_online'] == true;

    return ListTile(
      leading: CircleAvatar(
        backgroundImage: avatar != null ? NetworkImage(avatar) : null,
        child: avatar == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : "?") : null,
      ),
      title: Text(name),
      subtitle: Text(type == 'user' ? (isOnline ? 'Online' : 'Offline') : 'Grupo público'),
      onTap: () {
        if (type == 'user') {
          _iniciarConversaComUsuario(item['id'] as String);
        } else {
          _joinGroupAndOpen(item['id'] as String);
        }
      },
    );
  }

  Future<void> _joinGroupAndOpen(String groupId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;
      final exists = await supabase
          .from('participants')
          .select()
          .match({'conversation_id': groupId, 'user_id': meuUserId})
          .maybeSingle();

      if (exists == null) {
        await supabase.from('participants').insert({'conversation_id': groupId, 'user_id': meuUserId});
      }
      
      if (mounted) Navigator.of(context).popAndPushNamed('/chat', arguments: groupId);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao entrar no grupo: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Buscar utilizadores ou grupos...', border: InputBorder.none),
          onChanged: _searchUsers,
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                return _buildResultTile(_searchResults[index]);
              },
            ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.group_add),
        tooltip: 'Criar grupo',
        onPressed: () async {
          final result = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (_) => const CreateGroupDialog(),
          );
          if (result != null) {
            final name = result['name'] as String;
            final participants = List<String>.from(result['participants'] ?? []);
            await _criarGrupoSimples(name, participants);
          }
        },
      ),
    );
  }
}