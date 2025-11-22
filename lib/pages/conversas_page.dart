import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chat_app/services/presence_service.dart';
import 'package:chat_app/main.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ConversasPage extends StatefulWidget {
  const ConversasPage({super.key});

  @override
  State<ConversasPage> createState() => _ConversasPageState();
}

class _ConversasPageState extends State<ConversasPage> with RouteAware, SingleTickerProviderStateMixin {
  late TabController _tabController;
  final supabase = Supabase.instance.client;
  final _picker = ImagePicker();

  List<Map<String, dynamic>> _conversasAtivas = [];
  List<Map<String, dynamic>> _conversasArquivadas = [];
  List<Map<String, dynamic>> _statusList = [];
  List<Map<String, dynamic>> _callLogs = []; 
  bool _isLoading = true;
  
  // Variáveis para controlar os "Ouvintes" (Listeners)
  late final Stream<List<Map<String, dynamic>>> _presenceStream;
  RealtimeChannel? _messagesListener; // <--- NOVO: Escuta mensagens

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() => setState(() {})); 

    _carregarConversas();
    _carregarStatus();
    _carregarChamadas();
    
    // --- AQUI ESTÁ A MÁGICA DO TEMPO REAL ---
    // Escuta qualquer mudança na tabela de mensagens (Insert, Update, Delete)
    _messagesListener = supabase.channel('public:messages').onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'messages',
      callback: (payload) {
        // Se algo mudou, recarrega a lista!
        _carregarConversas();
      },
    ).subscribe();
    // ---------------------------------------

    _presenceStream = PresenceService.presenceStream();
    _presenceStream.listen((_) {
      if (mounted) setState(() {}); 
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _tabController.dispose();
    // Limpa o ouvinte para não gastar memória
    supabase.removeChannel(_messagesListener!); 
    super.dispose();
  }

  @override
  void didPopNext() {
    _carregarConversas();
    _carregarStatus();
    _carregarChamadas();
  }

  Future<void> _carregarConversas() async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return;
      
      final data = await supabase.from('v_user_conversations').select().eq('participant_id', userId).order('last_message_at', ascending: false);
      final List<Map<String, dynamic>> todas = List<Map<String, dynamic>>.from(data);
      final seenIds = <String>{};
      final unicas = todas.where((c) {
        final id = c['conversation_id'] as String?;
        if (id == null || id.isEmpty) return false;
        return seenIds.add(id);
      }).toList();

      if (mounted) {
        setState(() {
          _conversasAtivas = unicas.where((c) => c['is_archived'] != true).toList();
          _conversasArquivadas = unicas.where((c) => c['is_archived'] == true).toList();
          _isLoading = false;
        });
      }
    } catch (e) { if (mounted) setState(() => _isLoading = false); }
  }

  Future<void> _carregarChamadas() async {
    try {
      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;
      final data = await supabase.from('call_logs').select('*, profiles!receiver_id(name, avatar_url)').or('caller_id.eq.$myId,receiver_id.eq.$myId').order('created_at', ascending: false).limit(20);
      if (mounted) setState(() { _callLogs = List<Map<String, dynamic>>.from(data); });
    } catch (_) {}
  }

  Future<void> _alternarArquivamento(String conversaId, bool arquivar) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    try {
      await supabase.from('participants').update({'is_archived': arquivar}).match({'conversation_id': conversaId, 'user_id': userId});
      _carregarConversas();
    } catch (_) {}
  }

  Future<void> _carregarStatus() async {
    try {
      final yesterday = DateTime.now().subtract(const Duration(hours: 24)).toIso8601String();
      final data = await supabase.from('user_status').select('*, profiles(name, avatar_url)').gt('created_at', yesterday).order('created_at', ascending: false);
      if (mounted) setState(() { _statusList = List<Map<String, dynamic>>.from(data); });
    } catch (_) {}
  }

  Future<void> _postarStatus() async {
    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (pickedFile == null) return;
      final bytes = await pickedFile.readAsBytes();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_status.jpg';
      await supabase.storage.from('status').uploadBinary(fileName, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
      final url = supabase.storage.from('status').getPublicUrl(fileName);
      await supabase.from('user_status').insert({'user_id': supabase.auth.currentUser!.id, 'image_url': url});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Status postado!")));
      _carregarStatus();
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"))); }
  }

  void _verStatus(Map<String, dynamic> status) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.transparent, title: Text(status['profiles']['name'] ?? 'Usuário')), body: Center(child: Image.network(status['image_url'])))));
  }

  Widget _buildConversationTile(Map<String, dynamic> c) {
    final conversaId = c['conversation_id'];
    final name = c['display_name'] ?? "Conversa";
    final avatar = c['display_avatar'];
    
    // Formatação da última mensagem
    String lastMsg = c['last_message'] ?? "";
    if (lastMsg.startsWith('http')) {
       if (lastMsg.contains('/chat_media/') && (lastMsg.endsWith('.jpg') || lastMsg.endsWith('.png'))) {
         lastMsg = '📷 Foto';
       } else if (lastMsg.contains('/audio_messages/')) {
         lastMsg = '🎤 Áudio';
       } else if (lastMsg.contains('/chat_media/')) {
         lastMsg = '📄 Arquivo';
       }
    }

    final unreadCount = c['unread_count'] as int? ?? 0;
    final isArchived = c['is_archived'] == true;
    final lastTime = c['last_message_at'] != null ? DateTime.parse(c['last_message_at']).toLocal() : null;
    final timeStr = lastTime != null ? "${lastTime.hour.toString().padLeft(2,'0')}:${lastTime.minute.toString().padLeft(2,'0')}" : "";

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(radius: 26, backgroundColor: Colors.grey, backgroundImage: avatar != null ? NetworkImage(avatar) : null, child: avatar == null ? const Icon(Icons.person, color: Colors.white) : null),
      title: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis)), Text(timeStr, style: TextStyle(fontSize: 12, color: unreadCount > 0 ? const Color(0xFF25D366) : Colors.grey, fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal))]),
      subtitle: Row(children: [Expanded(child: Text(lastMsg, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey, fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal))), if (unreadCount > 0) Container(margin: const EdgeInsets.only(left: 10), padding: const EdgeInsets.all(6), decoration: const BoxDecoration(color: Color(0xFF25D366), shape: BoxShape.circle), child: Text(unreadCount.toString(), style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)))]),
      onTap: () => Navigator.of(context).pushNamed('/chat', arguments: conversaId).then((_) => _carregarConversas()),
      onLongPress: () {
        showModalBottomSheet(context: context, builder: (ctx) {
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: Icon(isArchived ? Icons.unarchive : Icons.archive), title: Text(isArchived ? 'Desarquivar conversa' : 'Arquivar conversa'), onTap: () { Navigator.pop(ctx); _alternarArquivamento(conversaId, !isArchived); })
          ]);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final secondaryColor = Theme.of(context).colorScheme.secondary;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, 
        title: const Text('ChatApp', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.camera_alt_outlined), onPressed: _postarStatus),
          IconButton(icon: const Icon(Icons.search), onPressed: () => Navigator.of(context).pushNamed('/search')),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'profile') Navigator.of(context).pushNamed('/profile');
              else if (value == 'logout') {
                final uid = supabase.auth.currentUser?.id;
                if (uid != null) await PresenceService.setOffline(uid);
                await supabase.auth.signOut();
                if (context.mounted) Navigator.of(context).pushReplacementNamed('/login');
              }
            },
            itemBuilder: (context) => [const PopupMenuItem(value: 'profile', child: Text('Configurações')), const PopupMenuItem(value: 'logout', child: Text('Sair'))],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: secondaryColor,
          labelColor: secondaryColor,
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [Tab(text: 'CONVERSAS'), Tab(text: 'STATUS'), Tab(text: 'CHAMADAS')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          RefreshIndicator(
            onRefresh: _carregarConversas,
            child: ListView(
              children: [
                if (_conversasArquivadas.isNotEmpty)
                  ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), leading: const Icon(Icons.archive_outlined, color: Colors.grey), title: const Text('Arquivadas', style: TextStyle(fontWeight: FontWeight.bold)), trailing: Text(_conversasArquivadas.length.toString(), style: const TextStyle(color: Colors.grey)), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArquivadasPage(conversas: _conversasArquivadas, onUnarchive: (id) => _alternarArquivamento(id, false))))),
                if (_conversasArquivadas.isNotEmpty) const Divider(height: 1),
                if (_conversasAtivas.isEmpty && !_isLoading && _conversasArquivadas.isEmpty)
                  const Padding(padding: EdgeInsets.all(40), child: Center(child: Text("Nenhuma conversa.")))
                else
                  ..._conversasAtivas.map((c) => _buildConversationTile(c)),
              ],
            ),
          ),
          ListView(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: Stack(children: [const CircleAvatar(radius: 26, backgroundColor: Colors.grey, child: Icon(Icons.person, color: Colors.white)), Positioned(bottom: 0, right: 0, child: Container(decoration: BoxDecoration(color: secondaryColor, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2)), child: const Icon(Icons.add, size: 20, color: Colors.white)))]),
                title: const Text("Meu status", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("Toque para atualizar seu status"),
                onTap: _postarStatus,
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text("Atualizações recentes", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey))),
              if (_statusList.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text("Nenhum status recente.", style: TextStyle(color: Colors.grey)))
              else ..._statusList.map((s) => ListTile(leading: Container(padding: const EdgeInsets.all(2), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: secondaryColor, width: 2)), child: CircleAvatar(radius: 22, backgroundColor: Colors.blueGrey, backgroundImage: s['profiles']['avatar_url']!=null?NetworkImage(s['profiles']['avatar_url']):null, child: s['profiles']['avatar_url']==null?const Icon(Icons.person):null)), title: Text(s['profiles']['name']??'Usuário', style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text("Hoje"), onTap: () => _verStatus(s))),
            ],
          ),
          RefreshIndicator(
            onRefresh: _carregarChamadas,
            child: _callLogs.isEmpty
                ? const Center(child: Text("Nenhuma chamada recente."))
                : ListView.builder(
                    itemCount: _callLogs.length,
                    itemBuilder: (context, index) {
                      final log = _callLogs[index];
                      final isMeCaller = log['caller_id'] == supabase.auth.currentUser?.id;
                      final isVideo = log['is_video'] == true;
                      final time = DateTime.parse(log['created_at']).toLocal();
                      final dateStr = "${time.day}/${time.month}, ${time.hour}:${time.minute.toString().padLeft(2,'0')}";
                      final name = log['profiles']?['name'] ?? (isMeCaller ? "Chamada enviada" : "Chamada recebida");
                      final avatar = log['profiles']?['avatar_url'];

                      return ListTile(
                        leading: CircleAvatar(radius: 26, backgroundImage: avatar!=null ? NetworkImage(avatar):null, child: avatar==null?const Icon(Icons.person):null),
                        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Row(children: [ Icon(isMeCaller ? Icons.call_made : Icons.call_received, size: 16, color: isMeCaller ? Colors.green : Colors.red), const SizedBox(width: 4), Text(dateStr)]),
                        trailing: Icon(isVideo ? Icons.videocam : Icons.call, color: secondaryColor),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: _buildFab(context),
    );
  }

  Widget _buildFab(BuildContext context) {
    if (_tabController.index == 0) return FloatingActionButton(onPressed: () => Navigator.of(context).pushNamed('/search'), child: const Icon(Icons.message));
    if (_tabController.index == 1) return FloatingActionButton(heroTag: "cam", onPressed: _postarStatus, child: const Icon(Icons.camera_alt));
    if (_tabController.index == 2) return FloatingActionButton(heroTag: "call", onPressed: (){}, child: const Icon(Icons.add_call));
    return const SizedBox.shrink();
  }
}

class ArquivadasPage extends StatelessWidget {
  final List<Map<String, dynamic>> conversas;
  final Function(String) onUnarchive;
  const ArquivadasPage({super.key, required this.conversas, required this.onUnarchive});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Arquivadas')),
      body: ListView.builder(
        itemCount: conversas.length,
        itemBuilder: (context, index) {
          final c = conversas[index];
          return ListTile(leading: CircleAvatar(backgroundColor: Colors.grey, backgroundImage: c['display_avatar']!=null?NetworkImage(c['display_avatar']):null, child: c['display_avatar']==null?const Icon(Icons.person):null), title: Text(c['display_name']??'Conversa'), subtitle: Text(c['last_message']??''), trailing: IconButton(icon: const Icon(Icons.unarchive), onPressed: () { onUnarchive(c['conversation_id']); Navigator.pop(context); }), onTap: () => Navigator.of(context).pushNamed('/chat', arguments: c['conversation_id']));
        },
      ),
    );
  }
}