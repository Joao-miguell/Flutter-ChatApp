// lib/pages/conversas_page.dart
import 'package:flutter/material.dart';
import 'package:chat_app/main.dart';

class ConversasPage extends StatefulWidget {
  const ConversasPage({super.key});

  @override
  State<ConversasPage> createState() => _ConversasPageState();
}

class _ConversasPageState extends State<ConversasPage> {
  late Future<List<Map<String, dynamic>>> _futureConversas;

  @override
  void initState() {
    super.initState();
    _futureConversas = _getConversas();
  }

  Future<List<Map<String, dynamic>>> _getConversas() {
    return supabase
        .from('v_user_conversations')
        .select()
        .eq('participant_id', supabase.auth.currentUser!.id)
        //.order('last_message_at', ascending: false) // opcional
        ;
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
              await supabase.auth.signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/login');
              }
            },
          ),
        ],
      ),

      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _futureConversas,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Erro: ${snapshot.error}'));
          }

          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(
              child: Text('Nenhuma conversa encontrada. Inicie uma na busca.'),
            );
          }

          final conversas = snapshot.data!;

          return ListView.builder(
            itemCount: conversas.length,
            itemBuilder: (context, index) {
              final c = conversas[index];
              final conversaId = c['conversation_id'];

              // Nome do outro participante (OU nome do grupo)
              final nomeConversa = c['display_name'] ?? "Conversa";

              // Avatar final da view
              final avatar = c['display_avatar'] as String?;

              // Última mensagem
              final lastMsg = c['last_message'] ?? "";

              return ListTile(
                leading: CircleAvatar(
                  backgroundImage:
                      avatar != null ? NetworkImage(avatar) : null,
                  child: avatar == null
                      ? Text(
                          nomeConversa.isNotEmpty
                              ? nomeConversa[0].toUpperCase()
                              : "?",
                        )
                      : null,
                ),
                title: Text(
                  nomeConversa,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  lastMsg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await Navigator.of(context)
                      .pushNamed('/chat', arguments: conversaId);

                  setState(() {
                    _futureConversas = _getConversas();
                  });
                },
              );
            },
          );
        },
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).pushNamed('/search');

          setState(() {
            _futureConversas = _getConversas();
          });
        },
        child: const Icon(Icons.add_comment),
        tooltip: 'Buscar usuários',
      ),
    );
  }
}
