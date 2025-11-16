// lib/pages/search_page.dart
import 'package:flutter/material.dart';
import 'package:chat_app/services/supabase_service.dart';

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

      // Busca por users e por grupos públicos com o termo
      final users = await supabase
          .from('profiles')
          .select()
          .ilike('name', '%$query%')
          .neq('id', meuUserId);

      // Grupos públicos (conversations.is_group = true AND is_public = true)
      final groups = await supabase
          .from('conversations')
          .select('id, name, avatar_url')
          .ilike('name', '%$query%')
          .eq('is_group', true)
          .eq('is_public', true);

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

  // Cria ou abre conversa com usuário
  Future<void> _iniciarConversaComUsuario(String outroUserId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;

      // Procura conversa privada já existente (usando participants)
      final existingConversations = await supabase
          .from('participants')
          .select('conversation_id')
          .inFilter('user_id', [meuUserId, outroUserId]);

      if (existingConversations != null && existingConversations.isNotEmpty) {
        final conversationIds = existingConversations.map((p) => p['conversation_id']).toSet().toList();
        final shared = await supabase
            .from('participants')
            .select('conversation_id')
            .inFilter('conversation_id', conversationIds)
            .eq('user_id', outroUserId);

        if (shared != null && shared.isNotEmpty) {
          final conversaId = shared.first['conversation_id'] as String;
          if (mounted) {
            Navigator.of(context).popAndPushNamed('/chat', arguments: conversaId);
          }
          return;
        }
      }

      // Cria nova conversa privada
      final conversaData = await supabase.from('conversations').insert({'is_group': false}).select().single();
      final conversaId = conversaData['id'] as String;

      // Adiciona participantes
      await supabase.from('participants').insert([
        {'conversation_id': conversaId, 'user_id': meuUserId},
        {'conversation_id': conversaId, 'user_id': outroUserId},
      ]);

      if (mounted) Navigator.of(context).popAndPushNamed('/chat', arguments: conversaId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erro ao iniciar conversa: $error'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // Cria um grupo simples (nome + participantes)
  Future<void> _criarGrupoSimples(String name, List<String> participantIds) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;
      final data = await supabase
          .from('conversations')
          .insert({'is_group': true, 'name': name, 'is_public': false})
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
        Navigator.of(context).pop(); // fecha modal/criar grupo
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
        child: avatar == null ? Text(name[0].toUpperCase()) : null,
      ),
      title: Text(name),
      subtitle: Text(type == 'user' ? (isOnline ? 'Online' : 'Offline') : 'Grupo público'),
      onTap: () {
        if (type == 'user') {
          _iniciarConversaComUsuario(item['id'] as String);
        } else {
          // entrar no grupo público: adiciona participante e abre
          _joinGroupAndOpen(item['id'] as String);
        }
      },
    );
  }

  Future<void> _joinGroupAndOpen(String groupId) async {
    try {
      final meuUserId = supabase.auth.currentUser!.id;
      // verifica se já é participante
      final exists = await supabase
          .from('participants')
          .select()
          .match({'conversation_id': groupId, 'user_id': meuUserId});
      if (exists == null || exists.isEmpty) {
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
            builder: (_) => _CreateGroupDialog(),
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

class _CreateGroupDialog extends StatefulWidget {
  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  String _name = '';
  List<Map<String, dynamic>> _found = [];
  List<String> _selected = [];
  final _ctrl = TextEditingController();
  bool _loading = false;

  Future<void> _search(String q) async {
    if (q.isEmpty) {
      setState(() => _found = []);
      return;
    }
    setState(() => _loading = true);
    final me = supabase.auth.currentUser!.id;
    final users = await supabase.from('profiles').select().ilike('name', '%$q%').neq('id', me);
    setState(() {
      _found = (users ?? []).cast<Map<String, dynamic>>();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Criar Grupo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            decoration: const InputDecoration(labelText: 'Nome do grupo'),
            onChanged: (v) => _name = v,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            decoration: const InputDecoration(labelText: 'Adicionar participantes (buscar)'),
            onChanged: _search,
          ),
          const SizedBox(height: 8),
          if (_loading) const CircularProgressIndicator(),
          if (!_loading)
            SizedBox(
              height: 120,
              child: ListView.builder(
                itemCount: _found.length,
                itemBuilder: (context, idx) {
                  final u = _found[idx];
                  final id = u['id'] as String;
                  final name = u['name'] as String? ?? '...';
                  final selected = _selected.contains(id);
                  return ListTile(
                    title: Text(name),
                    trailing: IconButton(
                      icon: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank),
                      onPressed: () {
                        setState(() {
                          if (selected) _selected.remove(id);
                          else _selected.add(id);
                        });
                      },
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: () {
            if (_name.trim().isEmpty || _selected.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nome e pelo menos 1 participante')));
              return;
            }
            Navigator.of(context).pop({'name': _name.trim(), 'participants': _selected});
          },
          child: const Text('Criar'),
        ),
      ],
    );
  }
}
