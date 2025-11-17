// lib/pages/conversas_page.dart
import 'package:flutter/material.dart';
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/presence_service.dart';

class ConversasPage extends StatefulWidget {
  const ConversasPage({super.key});

  @override
  State<ConversasPage> createState() => _ConversasPageState();
}

class _ConversasPageState extends State<ConversasPage> {
  late final Stream<List<Map<String, dynamic>>> _streamConversas;
  late final Stream<List<Map<String, dynamic>>> _presenceStream;
  Map<String, Map<String, dynamic>> _presenceCache = {};

  @override
  void initState() {
    super.initState();
    final userId = supabase.auth.currentUser!.id;

    _streamConversas = supabase
        .from('v_user_conversations')
        .stream(primaryKey: ['conversation_id'])
        .eq('participant_id', userId)
        .order('last_message_at', ascending: false);

    _presenceStream = PresenceService.presenceStream();
    _presenceStream.listen((rows) {
      // Atualiza cache de presença
      final map = <String, Map<String, dynamic>>{};
      for (var r in rows) {
        final id = r['user_id']?.toString();
        if (id != null) map[id] = Map<String, dynamic>.from(r);
      }
      if (mounted) {
        setState(() {
          _presenceCache = map;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas Conversas'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Meu Perfil',
            onPressed: () => Navigator.of(context).pushNamed('/profile'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair',
            onPressed: () async {
              final uid = supabase.auth.currentUser?.id;
              if (uid != null) await PresenceService.setOffline(uid);
              await supabase.auth.signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/login');
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _streamConversas,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final conversas = snapshot.data!;

          // 🟢 INÍCIO DA CORREÇÃO (Conversa Duplicada) 🟢
          // Garante que a lista é única (baseado no ID da conversa)
          final seenIds = <String>{};
          final uniqueConversas = conversas.where((c) {
            final id = c['conversation_id'] as String?;
            if (id == null || id.isEmpty) return false;
            // .add() retorna true se o item for NOVO no Set
            return seenIds.add(id);
          }).toList();
          // 🟢 FIM DA CORREÇÃO 🟢

          if (uniqueConversas.isEmpty) { // <-- Use uniqueConversas
            return const Center(child: Text("Nenhuma conversa ainda."));
          }

          return ListView.builder(
            itemCount: uniqueConversas.length, // <-- Use uniqueConversas
            itemBuilder: (context, index) {
              final c = uniqueConversas[index]; // <-- Use uniqueConversas
              final conversaId = c['conversation_id'] as String?;
              final name = (c['display_name'] ?? "Conversa") as String;
              final avatar = c['display_avatar'] as String?;
              final lastMsg = c['last_message'] ?? "";
              final typingUsers = c['typing_users'] ?? '';
              final subtitle = (typingUsers != null && (typingUsers as String).isNotEmpty)
                  ? "digitando..."
                  : lastMsg;

              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                  child: avatar == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : "?") : null,
                ),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  if (conversaId != null) {
                    Navigator.of(context).pushNamed('/chat', arguments: conversaId);
                  }
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Buscar usuários',
        child: const Icon(Icons.add_comment),
        onPressed: () async {
          await Navigator.of(context).pushNamed('/search');
        },
      ),
    );
  }
}