import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chat_app/services/presence_service.dart';
import 'package:chat_app/main.dart';
import 'package:image_picker/image_picker.dart'; // Para postar status
import 'package:http/http.dart' as http; // Para upload
import 'dart:convert'; // Para jsonEncode

class ConversasPage extends StatefulWidget {
  const ConversasPage({super.key});

  @override
  State<ConversasPage> createState() => _ConversasPageState();
}

class _ConversasPageState extends State<ConversasPage> with RouteAware, SingleTickerProviderStateMixin {
  late TabController _tabController;
  final supabase = Supabase.instance.client;
  final _picker = ImagePicker();

  List<Map<String, dynamic>> _conversas = [];
  List<Map<String, dynamic>> _statusList = [];
  bool _isLoading = true;
  
  // ignore: unused_field
  late final Stream<List<Map<String, dynamic>>> _presenceStream;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() => setState(() {})); 

    _carregarConversas();
    _carregarStatus();

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
    super.dispose();
  }

  @override
  void didPopNext() {
    _carregarConversas();
    _carregarStatus();
  }

  // --- LÓGICA DE CONVERSAS ---
  Future<void> _carregarConversas() async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return;
      
      final data = await supabase
          .from('v_user_conversations')
          .select()
          .eq('participant_id', userId)
          .order('last_message_at', ascending: false);

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

  // --- LÓGICA DE STATUS ---
  Future<void> _carregarStatus() async {
    try {
      // Busca status das últimas 24h
      final yesterday = DateTime.now().subtract(const Duration(hours: 24)).toIso8601String();
      
      final data = await supabase
          .from('user_status')
          .select('*, profiles(name, avatar_url)')
          .gt('created_at', yesterday)
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _statusList = List<Map<String, dynamic>>.from(data);
        });
      }
    } catch (e) {
      debugPrint('Erro status: $e');
    }
  }

  Future<void> _postarStatus() async {
    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (pickedFile == null) return;

      final bytes = await pickedFile.readAsBytes();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_status.jpg';

      // 1. Upload
      final res = await http.post(
        Uri.parse('https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'filename': fileName, 'mime': 'image/jpeg', 'folder': 'status'}),
      );
      
      if (res.statusCode != 200) throw 'Erro URL Upload';
      final d = jsonDecode(res.body);
      await http.put(Uri.parse(d['uploadUrl']), headers: {'Content-Type': 'image/jpeg'}, body: bytes);
      
      final url = 'https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/status/${d['key']}';

      // 2. Salvar no Banco
      await supabase.from('user_status').insert({
        'user_id': supabase.auth.currentUser!.id,
        'image_url': url,
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Status postado!")));
      _carregarStatus();

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro ao postar: $e")));
    }
  }

  void _verStatus(Map<String, dynamic> status) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        title: Text(status['profiles']['name'] ?? 'Usuário'),
      ),
      body: Center(child: Image.network(status['image_url'])),
    )));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondaryColor = theme.colorScheme.secondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ChatApp', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.camera_alt_outlined), onPressed: _postarStatus), // Atalho Câmera
          IconButton(icon: const Icon(Icons.search), onPressed: () => Navigator.of(context).pushNamed('/search')),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'profile') {
                Navigator.of(context).pushNamed('/profile');
              } else if (value == 'logout') {
                final uid = supabase.auth.currentUser?.id;
                if (uid != null) await PresenceService.setOffline(uid);
                await supabase.auth.signOut();
                if (context.mounted) Navigator.of(context).pushReplacementNamed('/login');
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'profile', child: Text('Configurações')),
              const PopupMenuItem(value: 'logout', child: Text('Sair')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: secondaryColor,
          indicatorWeight: 3,
          labelColor: secondaryColor,
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'CONVERSAS'),
            Tab(text: 'STATUS'),
            Tab(text: 'CHAMADAS'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // 1. ABA CONVERSAS
          RefreshIndicator(
            onRefresh: _carregarConversas,
            child: _conversas.isEmpty
                ? const Center(child: Text("Nenhuma conversa iniciada."))
                : ListView.builder(
                    itemCount: _conversas.length,
                    itemBuilder: (context, index) {
                      final c = _conversas[index];
                      final conversaId = c['conversation_id'];
                      final name = c['display_name'] ?? "Conversa";
                      final avatar = c['display_avatar'];
                      final lastMsg = c['last_message'] ?? "";
                      final typingUsers = c['typing_users'] ?? '';
                      final isTyping = (typingUsers != null && (typingUsers as String).isNotEmpty);
                      
                      final lastTime = c['last_message_at'] != null 
                          ? DateTime.parse(c['last_message_at']).toLocal() 
                          : null;
                      final timeStr = lastTime != null 
                          ? "${lastTime.hour.toString().padLeft(2,'0')}:${lastTime.minute.toString().padLeft(2,'0')}" 
                          : "";

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: Colors.grey,
                          backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                          child: avatar == null ? const Icon(Icons.person, color: Colors.white) : null,
                        ),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            Text(timeStr, style: TextStyle(fontSize: 12, color: isTyping ? secondaryColor : Colors.grey)),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            isTyping ? "digitando..." : lastMsg,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isTyping ? secondaryColor : Colors.grey,
                              fontStyle: isTyping ? FontStyle.italic : FontStyle.normal,
                            ),
                          ),
                        ),
                        onTap: () => Navigator.of(context).pushNamed('/chat', arguments: conversaId),
                      );
                    },
                  ),
          ),
          
          // 2. ABA STATUS (FUNCIONAL)
          ListView(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: Stack(
                  children: [
                    // CORREÇÃO: Removi o AssetImage quebrado e coloquei um ícone padrão
                    const CircleAvatar(radius: 26, backgroundColor: Colors.grey, child: Icon(Icons.person, color: Colors.white)),
                    Positioned(
                      bottom: 0, right: 0,
                      child: Container(
                        decoration: BoxDecoration(color: secondaryColor, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2)),
                        child: const Icon(Icons.add, size: 20, color: Colors.white),
                      ),
                    )
                  ],
                ),
                title: const Text("Meu status", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("Toque para atualizar seu status"),
                onTap: _postarStatus,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text("Atualizações recentes", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              ),
              // LISTA DE STATUS DO BANCO
              if (_statusList.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text("Nenhum status recente.", style: TextStyle(color: Colors.grey)))
              else
                ..._statusList.map((s) {
                  final profile = s['profiles'] ?? {};
                  final name = profile['name'] ?? 'Usuário';
                  final avatar = profile['avatar_url'];
                  final time = DateTime.parse(s['created_at']).toLocal();
                  final timeStr = "${time.hour}:${time.minute.toString().padLeft(2,'0')}";

                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: secondaryColor, width: 2)),
                      child: CircleAvatar(
                        radius: 22, 
                        backgroundColor: Colors.blueGrey, 
                        backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                        child: avatar == null ? const Icon(Icons.person, color: Colors.white) : null
                      ),
                    ),
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text("Hoje, às $timeStr"),
                    onTap: () => _verStatus(s),
                  );
                }),
            ],
          ),

          // 3. ABA CHAMADAS (Placeholder)
          ListView(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: CircleAvatar(radius: 26, backgroundColor: secondaryColor, child: const Icon(Icons.link, color: Colors.white)),
                title: const Text("Criar link da chamada", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("Compartilhe um link para sua chamada"),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text("Recentes", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              ),
              const Center(child: Padding(padding: EdgeInsets.all(20), child: Text("Nenhuma chamada recente"))),
            ],
          ),
        ],
      ),
      floatingActionButton: _buildFab(context),
    );
  }

  Widget _buildFab(BuildContext context) {
    IconData icon = Icons.message;
    VoidCallback? action = () => Navigator.of(context).pushNamed('/search');

    if (_tabController.index == 1) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        FloatingActionButton.small(heroTag: "edit", backgroundColor: Colors.grey[700], onPressed: (){}, child: const Icon(Icons.edit)),
        const SizedBox(height: 16),
        FloatingActionButton(heroTag: "cam", onPressed: _postarStatus, child: const Icon(Icons.camera_alt))
      ]);
    } else if (_tabController.index == 2) {
      icon = Icons.add_call;
      action = () {};
    }

    return FloatingActionButton(onPressed: action, child: Icon(icon));
  }
}