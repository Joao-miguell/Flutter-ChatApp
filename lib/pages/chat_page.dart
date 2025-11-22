import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/presence_service.dart';
import 'package:chat_app/services/typing_service.dart';
import 'package:chat_app/pages/call_page.dart';
import 'package:chat_app/services/reaction_service.dart';
import 'package:chat_app/services/profile_cache.dart';

// Pacotes de Áudio
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  String? _conversaId;
  Stream<List<Map<String, dynamic>>>? _messagesStream;
  final _messageController = TextEditingController();
  final _picker = ImagePicker();
  final ScrollController _scrollController = ScrollController();
  
  // Áudio
  late final AudioRecorder _audioRecorder;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  String? _playingMessageId;
  
  String? meuUserId;
  Map<String, List<Map<String, dynamic>>> _reactionsCache = {};

  StreamSubscription? _presenceSubscription;
  final Map<String, String> _typingUsers = {}; 
  bool _isGroup = false;
  String _chatTitle = 'Carregando...';
  String? _editingMessageId; 
  bool get _isEditing => _editingMessageId != null;

  final List<String> _deletedMessageIds = [];
  final List<Map<String, dynamic>> _pendingMessages = [];
  final Set<String> _handledRequestIds = {}; 

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingMessageId = null);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_conversaId != null) return;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args == null) return;
    _conversaId = args as String;
    meuUserId = supabase.auth.currentUser?.id;

    _messagesStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', _conversaId!)
        .order('created_at', ascending: true);

    _loadChatDetails();
    _listenToPresence();

    if (meuUserId != null) {
      PresenceService.setOnline(meuUserId!);
      PresenceService.setTyping(meuUserId!, null);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _scrollController.dispose();
    _presenceSubscription?.cancel();
    if (meuUserId != null) PresenceService.setTyping(meuUserId!, null);
    super.dispose();
  }

  // --- UTILITÁRIOS DE DATA ---
  bool _isSameDay(DateTime? d1, DateTime? d2) {
    if (d1 == null || d2 == null) return false;
    return d1.year == d2.year && d1.month == d2.month && d1.day == d2.day;
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    if (_isSameDay(now, date)) return "Hoje";
    if (_isSameDay(now.subtract(const Duration(days: 1)), date)) return "Ontem";
    return "${date.day.toString().padLeft(2,'0')}/${date.month.toString().padLeft(2,'0')}/${date.year}";
  }

  // --- ÁUDIO ---
  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        setState(() => _isRecording = true);
      }
    } catch (e) {
      debugPrint('Erro gravação: $e');
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) {
        final file = File(path);
        final bytes = await file.readAsBytes();
        await _uploadAndSendMedia('audio/m4a', 'audio.m4a', bytes, isMedia: false, type: 'audio');
      }
    } catch (e) {
      setState(() => _isRecording = false);
    }
  }

  Future<void> _playAudio(String url, String msgId) async {
    try {
      if (_playingMessageId == msgId) {
        await _audioPlayer.stop();
        setState(() => _playingMessageId = null);
      } else {
        await _audioPlayer.stop();
        await _audioPlayer.setSourceUrl(url);
        await _audioPlayer.resume();
        setState(() => _playingMessageId = msgId);
      }
    } catch (_) {}
  }

  // --- OUTRAS LÓGICAS ---
  Future<void> _loadChatDetails() async {
    if (_conversaId == null || meuUserId == null) return;
    try {
      final data = await supabase.from('conversations').select('is_group, name').eq('id', _conversaId!).single();
      final isGroup = data['is_group'] ?? false;
      String displayTitle = data['name'] ?? 'Chat';

      if (!isGroup) {
        final other = await supabase.from('participants').select('user_id').eq('conversation_id', _conversaId!).neq('user_id', meuUserId!).maybeSingle();
        if (other != null) {
          final p = await ProfileCache.getProfile(other['user_id']);
          if (p != null) displayTitle = p['name'] ?? 'Usuário';
        }
      }
      if (mounted) setState(() { _isGroup = isGroup; _chatTitle = displayTitle; });
    } catch (_) {}
  }

  void _listenToPresence() {
    _presenceSubscription = PresenceService.presenceStream().listen((states) {
      if (!mounted) return;
      final newTyping = <String, String>{};
      for (final s in states) {
        final uid = s['user_id'] as String?;
        final typingAt = s['typing_conversation'] as String?;
        if (uid != null && uid != meuUserId && typingAt == _conversaId) {
          final name = ProfileCache.cachedProfiles[uid]?['name'] ?? 'Alguém';
          newTyping[uid] = name;
        }
      }
      if (mounted) setState(() { _typingUsers.clear(); _typingUsers.addAll(newTyping); });
    });
  }

  Future<void> _enviarMensagem() async {
    final txt = _messageController.text.trim();
    if (txt.isEmpty || _conversaId == null) return;
    
    if (_isEditing) {
      await supabase.from('messages').update({'content': txt, 'is_edited': true}).eq('id', _editingMessageId!);
      setState(() { _editingMessageId = null; _messageController.clear(); });
    } else {
      _messageController.clear();
      await supabase.from('messages').insert({
        'sender_id': meuUserId, 'conversation_id': _conversaId, 'content': txt, 'type': 'text'
      });
      TypingService.stopTypingNow(userId: meuUserId!);
      // Rola para o fim após enviar
      Future.delayed(const Duration(milliseconds: 100), () {
        if(_scrollController.hasClients) _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      });
    }
  }

  Future<void> _uploadAndSendMedia(String mime, String name, List<int> bytes, {bool isMedia = false, String type = 'file'}) async {
    try {
      final bucket = type == 'audio' ? 'audio_messages' : 'chat_media';
      final res = await http.post(
        Uri.parse('https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'filename': '${DateTime.now().millisecondsSinceEpoch}_$name', 'mime': mime, 'folder': bucket}),
      );
      if (res.statusCode != 200) throw 'Erro URL';
      final d = jsonDecode(res.body);
      await http.put(Uri.parse(d['uploadUrl']), headers: {'Content-Type': mime}, body: bytes);
      final url = 'https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/$bucket/${d['key']}';
      
      await supabase.from('messages').insert({
        'sender_id': meuUserId, 'conversation_id': _conversaId, 'content': url, 'type': type, 'is_media': isMedia, 'file_name': name
      });
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro upload: $e'))); }
  }

  Future<void> _enviarImagem() async {
    final p = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (p != null) {
      final b = await p.readAsBytes();
      await _uploadAndSendMedia('image/jpeg', p.name, b, isMedia: true, type: 'image');
    }
  }

  Future<void> _enviarArquivo() async {
    final r = await FilePicker.platform.pickFiles();
    if (r != null && r.files.single.bytes != null) {
      await _uploadAndSendMedia('application/octet-stream', r.files.single.name, r.files.single.bytes!, type: 'file');
    }
  }

  void _onMessageLongPress(Map<String, dynamic> m) async {
    if (m['sender_id'] == meuUserId) {
        showModalBottomSheet(context: context, builder: (c) => Column(mainAxisSize: MainAxisSize.min, children: [
          if (m['type'] == 'text') ListTile(leading: const Icon(Icons.edit), title: const Text('Editar'), onTap: (){ Navigator.pop(c); setState(() { _editingMessageId = m['id']; _messageController.text = m['content']; }); }),
          ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: const Text('Apagar'), onTap: (){ Navigator.pop(c); supabase.from('messages').delete().eq('id', m['id']); }),
        ]));
    }
  }

  void _onTextChanged(String val) {
    if (_conversaId != null) TypingService.notifyTyping(conversationId: _conversaId!, userId: meuUserId!);
    setState(() {});
  }

  // Visualizador de Imagem em Tela Cheia
  void _openFullScreenImage(String url) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(child: InteractiveViewer(child: Image.network(url))),
    )));
  }

  @override
  Widget build(BuildContext context) {
    if (_messagesStream == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leadingWidth: 30,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back), 
          onPressed: () => Navigator.of(context).pop()
        ),
        title: Row(
          children: [
            const CircleAvatar(child: Icon(Icons.person)),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start, 
              children: [
                Text(_chatTitle, style: const TextStyle(fontSize: 16)),
                StreamBuilder(
                  stream: PresenceService.presenceStream(),
                  builder: (ctx, snap) {
                    String sub = '';
                    if (snap.hasData && !_isGroup) {
                      final isOnline = snap.data!.any((u) => u['user_id'] != meuUserId && (u['is_online'] ?? false));
                      if (isOnline) sub = 'Online';
                    }
                    if (_typingUsers.isNotEmpty && !_isGroup) sub = 'digitando...';
                    return Text(sub, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal));
                  }
                )
              ]
            ),
          ],
        ),
        actions: [
          // BOTÃO DE VÍDEO
          IconButton(
            icon: const Icon(Icons.videocam), 
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => CallPage(
                  callID: _conversaId!, // O ID da conversa é a "sala" da chamada
                  userID: meuUserId!,
                  userName: 'Eu', // Idealmente pegaria o nome do usuário
                  isVideo: true,
                )
              ));
            }
          ),
          // BOTÃO DE VOZ
          IconButton(
            icon: const Icon(Icons.call), 
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => CallPage(
                  callID: _conversaId!,
                  userID: meuUserId!,
                  userName: 'Eu',
                  isVideo: false, // Apenas áudio
                )
              ));
            }
          ),
          PopupMenuButton(itemBuilder: (context) => [const PopupMenuItem(child: Text('Dados do grupo'))]),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(image: DecorationImage(image: AssetImage('assets/images/background.jpg'), fit: BoxFit.cover)),
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _messagesStream,
                builder: (context, snapshot) {
                  final msgs = snapshot.data ?? [];
                  msgs.addAll(_pendingMessages);
                  msgs.sort((a, b) => (a['created_at']??'').compareTo(b['created_at']??''));

                  // Filtrar apagadas
                  final visibleMsgs = msgs.where((m) => !_deletedMessageIds.contains(m['id']) && !(m['type'] == 'join_request' && _handledRequestIds.contains(m['content']))).toList();

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: visibleMsgs.length,
                    itemBuilder: (ctx, i) {
                      final m = visibleMsgs[i];
                      final isMine = m['sender_id'] == meuUserId;
                      final type = m['type'];
                      final content = m['content'];
                      final time = DateTime.tryParse(m['created_at'].toString());
                      final timeStr = time != null ? "${time.hour.toString().padLeft(2,'0')}:${time.minute.toString().padLeft(2,'0')}" : "";

                      // Lógica do Separador de Data
                      bool showDate = false;
                      if (i == 0) {
                        showDate = true;
                      } else {
                        final prevTime = DateTime.tryParse(visibleMsgs[i - 1]['created_at'].toString());
                        showDate = !_isSameDay(time, prevTime);
                      }

                      return Column(
                        children: [
                          if (showDate && time != null)
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 12),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: const Color(0xFF1C262D).withOpacity(0.9), borderRadius: BorderRadius.circular(8)),
                              child: Text(_formatDateHeader(time), style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                            ),

                          Align(
                            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                              child: GestureDetector(
                                onLongPress: () => _onMessageLongPress(m),
                                child: Card(
                                  color: isMine ? const Color(0xFF005C4B) : const Color(0xFF1F2C34),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.only(topLeft: const Radius.circular(10), topRight: const Radius.circular(10), bottomLeft: isMine ? const Radius.circular(10) : Radius.zero, bottomRight: isMine ? Radius.zero : const Radius.circular(10))),
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (type == 'image') 
                                          GestureDetector(
                                            onTap: () => _openFullScreenImage(content),
                                            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(content)),
                                          )
                                        else if (type == 'audio') 
                                          Row(mainAxisSize: MainAxisSize.min, children: [
                                            IconButton(icon: Icon(_playingMessageId == m['id'] ? Icons.pause : Icons.play_arrow), onPressed: () => _playAudio(content, m['id'])),
                                            const Text("Áudio", style: TextStyle(color: Colors.white))
                                          ])
                                        else if (type == 'file')
                                          Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.file_present), Flexible(child: Text(m['file_name'] ?? 'Arquivo', style: const TextStyle(color: Colors.white)))])
                                        else
                                          Padding(
                                            padding: const EdgeInsets.only(right: 10, bottom: 0),
                                            child: Text(content, style: const TextStyle(fontSize: 16, color: Colors.white)),
                                          ),
                                        
                                        Align(alignment: Alignment.bottomRight, widthFactor: 1, child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                                          if(isMine) ...[const SizedBox(width:4), const Icon(Icons.done_all, size:15, color: Colors.blue)]
                                        ])),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            // BARRA DE INPUT
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(color: const Color(0xFF1F2C34), borderRadius: BorderRadius.circular(30)),
                      child: Row(children: [
                        IconButton(icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.grey), onPressed: (){}),
                        Expanded(
                          child: _isRecording 
                            ? const Padding(padding: EdgeInsets.only(left: 10), child: Text("Gravando... Solte para enviar", style: TextStyle(color: Colors.red)))
                            : TextField(
                                controller: _messageController,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(hintText: "Mensagem", border: InputBorder.none),
                                onChanged: _onTextChanged,
                                onSubmitted: (_) => _enviarMensagem(),
                              ),
                        ),
                        IconButton(icon: const Icon(Icons.attach_file, color: Colors.grey), onPressed: (){
                           showModalBottomSheet(context: context, builder: (c) => Container(height: 100, color: const Color(0xFF1F2C34), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              IconButton(icon: const Icon(Icons.image, color: Colors.purple, size: 40), onPressed: (){ Navigator.pop(c); _enviarImagem(); }),
                              const SizedBox(width: 30),
                              IconButton(icon: const Icon(Icons.insert_drive_file, color: Colors.indigo, size: 40), onPressed: (){ Navigator.pop(c); _enviarArquivo(); }),
                           ])));
                        }),
                        if (!_isRecording && _messageController.text.isEmpty)
                           IconButton(icon: const Icon(Icons.camera_alt, color: Colors.grey), onPressed: _enviarImagem),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 5),
                  GestureDetector(
                    onLongPress: _startRecording,
                    onLongPressUp: _stopRecordingAndSend,
                    onTap: () { if(_messageController.text.isNotEmpty) _enviarMensagem(); },
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: const Color(0xFF00A884),
                      child: Icon(_isRecording ? Icons.stop : (_messageController.text.isEmpty ? Icons.mic : Icons.send), color: Colors.white),
                    ),
                  )
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}