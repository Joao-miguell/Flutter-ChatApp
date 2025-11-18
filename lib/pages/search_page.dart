// lib/pages/search_page.dart
import 'package:flutter/material.dart';
import 'package:chat_app/services/supabase_service.dart';
import 'dialogs/create_group_dialog.dart'; 

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

      // Busca por grupos (Públicos E Privados)
      // 🟢 AGORA TRAZ 'is_public' TAMBÉM
      final groups = await supabase
          .from('conversations')
          .select('id, name, avatar_url, is_public') 
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
            'is_public': g['is_public'], // 🟢 Guarda se é público
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

  Future<void> _iniciarConversaComUsuario(String outroUserId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;
      final myConversationsResponse = await supabase
          .from('participants')
          .select('conversation_id')
          .eq('user_id', meuUserId);

      final myConversationIds = myConversationsResponse
          .map((p) => p['conversation_id'] as String)
          .toList();

      if (myConversationIds.isNotEmpty) {
        final sharedPrivateChatResponse = await supabase
            .from('participants')
            .select('conversation_id, conversations!inner(is_group)') 
            .inFilter('conversation_id', myConversationIds) 
            .eq('user_id', outroUserId) 
            .eq('conversations.is_group', false)
            .maybeSingle(); 

        if (sharedPrivateChatResponse != null) {
          final conversaId = sharedPrivateChatResponse['conversation_id'] as String;
          if (mounted) {
            Navigator.of(context).popAndPushNamed('/chat', arguments: conversaId);
          }
          return;
        }
      }
      
      throw Exception('Criando nova...');
    } catch (_) {
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

  // 🟢 ATUALIZADO: Recebe isPublic e salva no banco
  Future<void> _criarGrupoSimples(String name, List<String> participantIds, bool isPublic) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;
      final data = await supabase
          .from('conversations')
          .insert({
            'is_group': true, 
            'name': name, 
            'is_public': isPublic // 🟢 Usa o valor escolhido
          }) 
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
    
    // 🟢 Verifica se é público (com segurança para null)
    final isPublic = item['is_public'] == true; 

    String subText;
    if (type == 'user') {
      subText = isOnline ? 'Online' : 'Offline';
    } else {
      // 🟢 Mostra status do grupo na lista
      subText = isPublic ? 'Grupo Público' : 'Grupo Privado (Requer aprovação)';
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundImage: avatar != null ? NetworkImage(avatar) : null,
        child: avatar == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?') : null,
      ),
      title: Text(name),
      subtitle: Text(subText),
      // Mostra cadeado se for privado
      trailing: (type == 'group' && !isPublic) ? const Icon(Icons.lock_outline, size: 16) : null,
      onTap: () {
        if (type == 'user') {
          _iniciarConversaComUsuario(item['id'] as String);
        } else {
          // 🟢 Passa se é público ou privado para a lógica de entrada
          _joinGroupLogic(item['id'] as String, isPublic);
        }
      },
    );
  }

  // 🟢 LÓGICA DE ENTRADA 🟢
  Future<void> _joinGroupLogic(String groupId, bool isPublic) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;

      // 1. Verifica se JÁ SOU participante
      final exists = await supabase
          .from('participants')
          .select()
          .match({'conversation_id': groupId, 'user_id': meuUserId})
          .maybeSingle();

      if (exists != null) {
        // Já estou no grupo, só abre
        if (mounted) Navigator.of(context).popAndPushNamed('/chat', arguments: groupId);
        return;
      }

      if (isPublic) {
        // 2. Grupo PÚBLICO: Entra direto
        await supabase.from('participants').insert({'conversation_id': groupId, 'user_id': meuUserId});
        if (mounted) Navigator.of(context).popAndPushNamed('/chat', arguments: groupId);
      } else {
        // 3. Grupo PRIVADO: Manda solicitação
        _sendJoinRequest(groupId);
      }

    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro: $e')));
    }
  }

  // 🟢 ENVIAR SOLICITAÇÃO 🟢
  Future<void> _sendJoinRequest(String groupId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;

      // Verifica se já pediu antes
      final existingReq = await supabase
          .from('join_requests')
          .select()
          .match({'conversation_id': groupId, 'user_id': meuUserId, 'status': 'pending'})
          .maybeSingle();

      if (existingReq != null) {
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Já existe uma solicitação pendente.')));
         return;
      }

      // 1. Cria a solicitação na tabela
      final req = await supabase
          .from('join_requests')
          .insert({'conversation_id': groupId, 'user_id': meuUserId, 'status': 'pending'})
          .select()
          .single();
      
      final reqId = req['id'] as String;

      // 2. Cria uma MENSAGEM especial no grupo avisando
      // O 'content' guarda o ID da solicitação para facilitar a aprovação
      await supabase.from('messages').insert({
        'conversation_id': groupId,
        'sender_id': meuUserId,
        'content': reqId, // Guardamos o ID da request
        'type': 'join_request', // Tipo especial
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Solicitação enviada! Aguarde aprovação.'), backgroundColor: Colors.blue),
        );
      }

    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao solicitar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Buscar usuários ou grupos...', border: InputBorder.none),
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
            // 🟢 Pega a escolha do usuário
            final isPublic = result['is_public'] == true;
            await _criarGrupoSimples(name, participants, isPublic);
          }
        },
      ),
    );
  }
}