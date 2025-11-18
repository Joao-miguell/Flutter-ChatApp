// lib/pages/conversas_page.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart'; // 🟢 Import necessário
import 'package:chat_app/services/presence_service.dart';
import 'package:chat_app/main.dart'; // Necessário para acessar o routeObserver

class ConversasPage extends StatefulWidget {
  const ConversasPage({super.key});

  @override
  State<ConversasPage> createState() => _ConversasPageState();
}

class _ConversasPageState extends State<ConversasPage> with RouteAware {
  // 🟢 CORREÇÃO: Definimos o cliente Supabase aqui para evitar erros de importação
  final supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _conversas = [];
  bool _isLoading = true;
  
  late final Stream<List<Map<String, dynamic>>> _presenceStream;
  Map<String, Map<String, dynamic>> _presenceCache = {};

  @override
  void initState() {
    super.initState();
    
    // Carrega conversas ao iniciar
    _carregarConversas();

    // Configura presença (online/digitando)
    _presenceStream = PresenceService.presenceStream();
    _presenceStream.listen((rows) {
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Se inscreve para ouvir mudanças de rota (quando volta para esta tela)
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    // Remove inscrição
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  // Chamado quando voltamos para esta tela (ex: saindo do Chat)
  @override
  void didPopNext() {
    _carregarConversas(); // Força a atualização da lista
  }

  // Busca manual no banco
  Future<void> _carregarConversas() async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return;
      
      // Faz o select na View
      final data = await supabase
          .from('v_user_conversations')
          .select()
          .eq('participant_id', userId)
          .order('last_message_at', ascending: false);

      // Lógica de De-Duplicação
      final seenIds = <String>{};
      final uniqueConversas = (data as List<dynamic>).map((e) => e as Map<String, dynamic>).where((c) {
        final id = c['conversation_id'] as String?;
        if (id == null || id.isEmpty) return false;
        return seenIds.add(id);
      }).toList();

      if (mounted) {
        setState(() {
          _conversas = uniqueConversas;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Erro ao carregar conversas: $e');
      if (mounted) setState(() => _isLoading = false);
    }
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
      body: RefreshIndicator(
        onRefresh: _carregarConversas,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _conversas.isEmpty
                ? const Center(child: Text("Nenhuma conversa ainda."))
                : ListView.builder(
                    itemCount: _conversas.length,
                    itemBuilder: (context, index) {
                      final c = _conversas[index];
                      final conversaId = c['conversation_id'] as String?;
                      final name = (c['display_name'] ?? "Conversa") as String;
                      final avatar = c['display_avatar'] as String?;
                      final lastMsg = c['last_message'] ?? "";
                      
                      // Verifica presença para mostrar "digitando..."
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
                  ),
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