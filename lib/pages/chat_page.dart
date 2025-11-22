import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/presence_service.dart';
import 'package:chat_app/services/typing_service.dart';
import 'package:chat_app/services/reaction_service.dart';
import 'package:chat_app/services/profile_cache.dart';
import 'package:url_launcher/url_launcher.dart';

// Pacotes de Áudio
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// Pacote de Emoji
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

// Página de Chamada
import 'package:chat_app/pages/call_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  String? _conversaId;
  Stream<List<Map<String, dynamic>>>? _messagesStream;
  StreamSubscription? _msgSubscription; // <--- NOVO: Para monitorar leitura

  final _messageController = TextEditingController();
  final _picker = ImagePicker();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  
  // Áudio
  late final AudioRecorder _audioRecorder;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  String? _playingMessageId;
  
  List<int> _webAudioBytes = [];
  StreamSubscription? _recordStreamSubscription;

  bool _showEmojiPicker = false;

  String? meuUserId;
  Map<String, List<Map<String, dynamic>>> _reactionsCache = {};

  StreamSubscription? _presenceSubscription;
  final Map<String, String> _typingUsers = {}; 
  bool _isGroup = false;
  String _chatTitle = 'Carregando...';
  String? _chatAvatar;
  String? _targetUserId; 

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

    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        setState(() {
          _showEmojiPicker = false;
        });
      }
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

    // Configura o Stream e o Listener de Leitura
    final stream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', _conversaId!)
        .order('created_at', ascending: true);
    
    _messagesStream = stream;

    // --- CORREÇÃO DA LEITURA ---
    _msgSubscription?.cancel();
    _msgSubscription = stream.listen((msgs) {
      if (msgs.isNotEmpty) {
        // Pega a mensagem mais recente recebida
        final lastMsg = msgs.last;
        final lastTime = lastMsg['created_at'];
        // Marca como lido usando o horário DA MENSAGEM (infalível)
        if (lastTime != null) {
          _marcarComoLida(lastTime);
        }
      }
    });
    // --------------------------

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
    _recordStreamSubscription?.cancel();
    _scrollController.dispose();
    _focusNode.dispose();
    _presenceSubscription?.cancel();
    _msgSubscription?.cancel(); // <--- Importante cancelar
    if (meuUserId != null) PresenceService.setTyping(meuUserId!, null);
    super.dispose();
  }

  // --- MARCAR LIDA (Agora recebe o horário certo) ---
  Future<void> _marcarComoLida(String timestamp) async {
    if (_conversaId == null || meuUserId == null) return;
    try {
      await supabase.from('participants').update({
        'last_read_at': timestamp, 
      }).match({
        'conversation_id': _conversaId!,
        'user_id': meuUserId!,
      });
    } catch (_) {}
  }

  // --- UTILITÁRIOS ---
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

  Future<void> _abrirArquivo(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Não foi possível abrir o arquivo.")));
    }
  }

  // --- ÁUDIO ---
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecordingAndSend();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        setState(() => _isRecording = true);

        if (kIsWeb) {
          _webAudioBytes = [];
          final stream = await _audioRecorder.startStream(const RecordConfig());
          _recordStreamSubscription = stream.listen((data) {
            _webAudioBytes.addAll(data);
          });
        } else {
          final tempDir = await getTemporaryDirectory();
          final path = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
          await _audioRecorder.start(const RecordConfig(), path: path);
        }
      }
    } catch (e) {
      debugPrint('Erro gravação: $e');
      setState(() => _isRecording = false);
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      String? path;
      
      if (kIsWeb) {
        await _audioRecorder.stop(); 
        _recordStreamSubscription?.cancel();
      } else {
        path = await _audioRecorder.stop();
      }
      
      setState(() => _isRecording = false);

      List<int>? bytes;
      
      if (kIsWeb) {
        if (_webAudioBytes.isNotEmpty) bytes = _webAudioBytes;
      } else if (path != null) {
        final file = XFile(path);
        bytes = await file.readAsBytes();
      }

      if (bytes != null && bytes.isNotEmpty) {
        await _uploadAndSendMedia('audio/m4a', 'audio.m4a', bytes, isMedia: false, type: 'audio');
      }
    } catch (e) {
      debugPrint("Erro ao parar áudio: $e");
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

  // --- CHAMADA ---
  Future<void> _logCallAndStart(bool isVideo) async {
    if (meuUserId == null || _conversaId == null) return;
    try {
      await supabase.from('call_logs').insert({
        'caller_id': meuUserId,
        'receiver_id': _targetUserId,
        'conversation_id': _conversaId,
        'is_video': isVideo
      });
    } catch (e) { debugPrint('Erro call: $e'); }

    if (mounted) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => CallPage(
          callID: _conversaId!,
          userID: meuUserId!,
          userName: 'Eu',
          isVideo: isVideo,
        )
      ));
    }
  }

  // --- EMOJI ---
  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      _focusNode.requestFocus(); 
    } else {
      _focusNode.unfocus(); 
    }
    setState(() {
      _showEmojiPicker = !_showEmojiPicker;
    });
  }

  void _onEmojiSelected(Category? category, Emoji emoji) {
    _messageController.text = _messageController.text + emoji.emoji;
    _onTextChanged(_messageController.text);
  }

  // --- LÓGICA GERAL ---
  Future<void> _loadChatDetails() async {
    if (_conversaId == null || meuUserId == null) return;
    try {
      final data = await supabase.from('conversations').select('is_group, name, avatar_url').eq('id', _conversaId!).single();
      final isGroup = data['is_group'] ?? false;
      String displayTitle = data['name'] ?? 'Chat';
      String? displayAvatar = data['avatar_url'];
      String? targetId;

      if (!isGroup) {
        final other = await supabase.from('participants').select('user_id').eq('conversation_id', _conversaId!).neq('user_id', meuUserId!).maybeSingle();
        if (other != null) {
          targetId = other['user_id'];
          final p = await ProfileCache.getProfile(targetId!);
          if (p != null) {
            displayTitle = p['name'] ?? 'Usuário';
            displayAvatar = p['avatar_url'];
          }
        }
      }
      
      if (mounted) {
        setState(() { 
          _isGroup = isGroup; 
          _chatTitle = displayTitle;
          _chatAvatar = displayAvatar;
          _targetUserId = targetId;
        });
      }
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
      Future.delayed(const Duration(milliseconds: 100), () {
        if(_scrollController.hasClients) _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      });
    }
  }

  Future<void> _uploadAndSendMedia(String mime, String name, List<int> bytes, {bool isMedia = false, String type = 'file'}) async {
    try {
      final bucket = type == 'audio' ? 'audio_messages' : 'chat_media';
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_$name';
      
      await supabase.storage.from(bucket).uploadBinary(
        fileName,
        Uint8List.fromList(bytes),
        fileOptions: FileOptions(contentType: mime),
      );

      final url = supabase.storage.from(bucket).getPublicUrl(fileName);
      
      await supabase.from('messages').insert({
        'sender_id': meuUserId, 
        'conversation_id': _conversaId, 
        'content': url, 
        'type': type, 
        'is_media': isMedia, 
        'file_name': name
      });
    } catch (e) { 
      debugPrint('Erro upload: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao enviar: $e'))); 
    }
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

  Widget _buildReactionsRow(String messageId) {
    final list = _reactionsCache[messageId] ?? [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 4, children: list.map((r) => Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text(r['emoji'] ?? '', style: const TextStyle(fontSize: 12)), const SizedBox(width: 4), Text(r['count'].toString(), style: const TextStyle(fontSize: 10, color: Colors.white70))]))).toList()),
    );
  }

  Future<void> _refreshReactions(List<Map<String, dynamic>> messages) async {
    if (!mounted) return;
    for (var m in messages) {
      final mid = m['id'] as String;
      if (mid.startsWith('temp-')) continue;
      final rows = await supabase.from('reactions').select('emoji').eq('message_id', mid);
      final agg = <String, int>{};
      if (rows != null) {
        for (var r in rows) {
          final e = r['emoji'] as String? ?? '';
          if (e.isNotEmpty) agg[e] = (agg[e] ?? 0) + 1;
        }
      }
      _reactionsCache[mid] = agg.entries.map((e) => {'emoji': e.key, 'count': e.value}).toList();
    }
    if (mounted) setState(() {});
  }

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

    final theme = Theme.of(context);
    final inputColor = theme.colorScheme.surfaceContainerHighest;
    final accentColor = theme.colorScheme.secondary;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leadingWidth: 30,
        // SETA DE VOLTAR
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.grey,
              backgroundImage: _chatAvatar != null ? NetworkImage(_chatAvatar!) : null,
              child: _chatAvatar == null ? const Icon(Icons.person, color: Colors.white, size: 20) : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, 
                children: [
                  Text(_chatTitle, style: const TextStyle(fontSize: 16)),
                  StreamBuilder(
                    stream: PresenceService.presenceStream(),
                    builder: (ctx, snap) {
                      String text = '';
                      Color textColor = Colors.white70; 
                      if (snap.hasData && !_isGroup) {
                        final user = snap.data!.firstWhere((u) => u['user_id'] == _targetUserId, orElse: () => {});
                        if (user.isNotEmpty) {
                           final isOnlineDB = user['is_online'] == true;
                           final updatedAt = DateTime.tryParse(user['updated_at'].toString());
                           if (isOnlineDB && updatedAt != null && DateTime.now().difference(updatedAt.toLocal()).inSeconds < 120) text = 'Online';
                        }
                      }
                      if (_typingUsers.isNotEmpty && !_isGroup) {
                        text = 'digitando...';
                        textColor = accentColor; 
                      }
                      return Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: textColor, fontStyle: text == 'digitando...' ? FontStyle.italic : FontStyle.normal));
                    }
                  )
                ]
              ),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.videocam), onPressed: () => _logCallAndStart(true)),
          IconButton(icon: const Icon(Icons.call), onPressed: () => _logCallAndStart(false)),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'exit') Navigator.of(context).pop(); 
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'info', child: Text('Dados do grupo')),
              const PopupMenuItem(value: 'exit', child: Text('Sair da conversa')),
            ]
          ),
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

                      bool showDate = false;
                      if (i == 0) {
                        showDate = true;
                      } else {
                        final prevTime = DateTime.tryParse(visibleMsgs[i - 1]['created_at'].toString());
                        showDate = !_isSameDay(time, prevTime);
                      }

                      final bubbleColor = isMine 
                          ? theme.colorScheme.tertiary 
                          : theme.colorScheme.surfaceContainerHighest; 

                      return Column(
                        children: [
                          if (showDate && time != null)
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 12),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: theme.scaffoldBackgroundColor.withOpacity(0.8), borderRadius: BorderRadius.circular(8)),
                              child: Text(_formatDateHeader(time), style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.7), fontSize: 12, fontWeight: FontWeight.bold)),
                            ),

                          Align(
                            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                              child: GestureDetector(
                                onLongPress: () => _onMessageLongPress(m),
                                child: Card(
                                  color: bubbleColor,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.only(topLeft: const Radius.circular(10), topRight: const Radius.circular(10), bottomLeft: isMine ? const Radius.circular(10) : Radius.zero, bottomRight: isMine ? Radius.zero : const Radius.circular(10))),
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (type == 'image') 
                                          GestureDetector(onTap: () => _openFullScreenImage(content), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(content)))
                                        else if (type == 'audio') 
                                          Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: Icon(_playingMessageId == m['id'] ? Icons.pause : Icons.play_arrow), onPressed: () => _playAudio(content, m['id'])), const Text("Áudio", style: TextStyle(color: Colors.white))])
                                        else if (type == 'file')
                                          GestureDetector(
                                            onTap: () => _abrirArquivo(content),
                                            child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.file_present), Flexible(child: Text(m['file_name'] ?? 'Arquivo', style: const TextStyle(color: Colors.white, decoration: TextDecoration.underline)))])
                                          )
                                        else
                                          Padding(padding: const EdgeInsets.only(right: 10, bottom: 0), child: Text(content, style: const TextStyle(fontSize: 16, color: Colors.white))),
                                        
                                        Align(alignment: Alignment.bottomRight, widthFactor: 1, child: Row(mainAxisSize: MainAxisSize.min, children: [Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.white54)), if(isMine) ...[const SizedBox(width:4), Icon(Icons.done_all, size:15, color: accentColor)]])),
                                        _buildReactionsRow(m['id']),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(color: inputColor, borderRadius: BorderRadius.circular(30)),
                          child: Row(children: [
                            IconButton(icon: Icon(_showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions_outlined, color: Colors.grey), onPressed: _toggleEmojiPicker),
                            Expanded(
                              child: _isRecording 
                                ? const Padding(padding: EdgeInsets.only(left: 10), child: Text("Gravando... Toque para parar", style: TextStyle(color: Colors.red)))
                                : TextField(
                                    controller: _messageController,
                                    focusNode: _focusNode,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: const InputDecoration(hintText: "Mensagem", border: InputBorder.none),
                                    onChanged: _onTextChanged,
                                    onSubmitted: (_) => _enviarMensagem(),
                                  ),
                            ),
                            IconButton(icon: const Icon(Icons.attach_file, color: Colors.grey), onPressed: (){
                               showModalBottomSheet(context: context, backgroundColor: theme.scaffoldBackgroundColor, builder: (c) => Container(height: 100, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
                        onTap: () { 
                          if (_messageController.text.isNotEmpty) {
                            _enviarMensagem();
                          } else {
                            _toggleRecording(); 
                          }
                        },
                        child: CircleAvatar(
                          radius: 24,
                          backgroundColor: accentColor,
                          child: Icon(
                            _isRecording ? Icons.stop : (_messageController.text.isEmpty ? Icons.mic : Icons.send),
                            color: Colors.white
                          ),
                        ),
                      )
                    ]),
                  ),
                  
                  if (_showEmojiPicker)
                    SizedBox(
                      height: 250,
                      child: EmojiPicker(
                        onEmojiSelected: (category, emoji) {
                          _onEmojiSelected(category, emoji);
                        },
                        config: Config(
                          height: 250,
                          checkPlatformCompatibility: true,
                          emojiViewConfig: EmojiViewConfig(
                            columns: 7,
                            emojiSizeMax: 32 * (kIsWeb ? 1.0 : 1.30),
                            verticalSpacing: 0,
                            horizontalSpacing: 0,
                            gridPadding: EdgeInsets.zero,
                            recentsLimit: 28,
                            buttonMode: ButtonMode.MATERIAL,
                            backgroundColor: theme.scaffoldBackgroundColor,
                          ),
                          categoryViewConfig: CategoryViewConfig(
                            initCategory: Category.RECENT,
                            backgroundColor: theme.scaffoldBackgroundColor,
                            indicatorColor: accentColor,
                            iconColor: Colors.grey,
                            iconColorSelected: accentColor,
                            backspaceColor: accentColor,
                            categoryIcons: const CategoryIcons(),
                          ),
                          skinToneConfig: SkinToneConfig(
                            dialogBackgroundColor: inputColor,
                            indicatorColor: Colors.grey,
                            enabled: true,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}