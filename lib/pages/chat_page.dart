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
import 'package:chat_app/services/reaction_service.dart';
import 'package:chat_app/services/profile_cache.dart';

// Pacotes de Áudio e Permissões
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

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
  
  late final AudioRecorder _audioRecorder;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  String? _playingMessageId;
  
  String? meuUserId;
  Map<String, List<Map<String, dynamic>>> _reactionsCache = {};

  StreamSubscription? _presenceSubscription;
  final Map<String, String> _typingUsers = {}; 
  bool _isGroup = false;
  bool _isLoadingInfo = true;
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
    _audioPlayer.onPlayerComplete.listen((event) {
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
    _presenceSubscription?.cancel();
    if (meuUserId != null) PresenceService.setTyping(meuUserId!, null);
    super.dispose();
  }

  // --- LÓGICA DE ÁUDIO ---
  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        setState(() => _isRecording = true);
      } else {
        _showError("Permissão de microfone negada.");
      }
    } catch (e) {
      _showError("Erro ao iniciar gravação: $e");
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) {
        final file = File(path);
        final bytes = await file.readAsBytes();
        await _uploadAndSendMedia('audio/m4a', 'audio_message.m4a', bytes, isMedia: false, type: 'audio');
      }
    } catch (e) {
      setState(() => _isRecording = false);
      _showError("Erro ao parar/enviar áudio: $e");
    }
  }

  Future<void> _playAudio(String url, String messageId) async {
    try {
      if (_playingMessageId == messageId) {
        await _audioPlayer.stop();
        setState(() => _playingMessageId = null);
      } else {
        await _audioPlayer.stop();
        await _audioPlayer.setSourceUrl(url);
        await _audioPlayer.resume();
        setState(() => _playingMessageId = messageId);
      }
    } catch (e) {
      _showError("Erro ao reproduzir: $e");
    }
  }
  // --- FIM LÓGICA DE ÁUDIO ---

  Future<void> _loadChatDetails() async {
    if (_conversaId == null || meuUserId == null) return;
    try {
      final data = await supabase.from('conversations').select('is_group, name').eq('id', _conversaId!).single();
      final isGroup = data['is_group'] ?? false;
      String displayTitle = data['name'] ?? 'Chat';

      if (!isGroup) {
        final otherParticipant = await supabase.from('participants').select('user_id').eq('conversation_id', _conversaId!).neq('user_id', meuUserId!).maybeSingle();
        if (otherParticipant != null) {
          final profile = await ProfileCache.getProfile(otherParticipant['user_id']);
          if (profile != null) displayTitle = profile['name'] ?? 'Usuário';
        }
      }
      if (mounted) setState(() { _isGroup = isGroup; _chatTitle = displayTitle; _isLoadingInfo = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoadingInfo = false);
    }
  }

  void _listenToPresence() {
    _presenceSubscription = PresenceService.presenceStream().listen((states) {
      if (!mounted) return;
      final newTypingUsers = <String, String>{};
      for (final state in states) {
        final userId = state['user_id'] as String?;
        final typingAt = state['typing_conversation'] as String?;
        final userName = ProfileCache.cachedProfiles[userId]?['name'] ?? 'Alguém';
        if (userId != null && userId != meuUserId && typingAt == _conversaId) {
          newTypingUsers[userId] = userName;
        }
      }
      if (mounted) setState(() { _typingUsers.clear(); _typingUsers.addAll(newTypingUsers); });
    });
  }

  Future<void> _enviarMensagem() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _conversaId == null) return;
    final id = supabase.auth.currentUser!.id;

    if (_isEditing) {
      try {
        await supabase.from('messages').update({'content': content, 'is_edited': true}).eq('id', _editingMessageId!);
        setState(() { _editingMessageId = null; _messageController.clear(); });
      } catch (e) { _showError('Erro ao editar: $e'); }
    } else {
      _messageController.clear();
      try {
        await supabase.from('messages').insert({
          'sender_id': id, 'conversation_id': _conversaId, 'content': content, 'type': 'text'
        });
        TypingService.stopTypingNow(userId: id);
      } catch (error) { _showError('Erro ao enviar: $error'); }
    }
  }

  Future<void> _uploadAndSendMedia(String mimeType, String fileName, List<int> fileBytes, {bool isMedia = false, String type = 'file'}) async {
    try {
      final bucketName = type == 'audio' ? 'audio_messages' : 'chat_media';
      final res = await http.post(
        Uri.parse('https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'filename': '${DateTime.now().millisecondsSinceEpoch}_$fileName', 'mime': mimeType, 'folder': bucketName}),
      );
      if (res.statusCode != 200) throw 'Erro upload.';
      final data = jsonDecode(res.body);
      await http.put(Uri.parse(data['uploadUrl']), headers: {'Content-Type': mimeType}, body: fileBytes);
      final finalUrl = 'https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/$bucketName/${data['key']}';
      await supabase.from('messages').insert({'sender_id': meuUserId, 'conversation_id': _conversaId, 'content': finalUrl, 'is_media': isMedia, 'type': type, 'file_name': fileName});
    } catch (error) { _showError('Erro no upload: $error'); }
  }

  Future<void> _enviarImagem() async {
    final pickedFile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      await _uploadAndSendMedia('image/jpeg', pickedFile.name, bytes, isMedia: true, type: 'image');
    }
  }

  Future<void> _enviarArquivoLeve() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.bytes != null) {
      if (result.files.single.size > 20 * 1024 * 1024) { _showError('Arquivo muito grande.'); return; }
      await _uploadAndSendMedia('application/octet-stream', result.files.single.name, result.files.single.bytes!, isMedia: false, type: 'file');
    }
  }

  void _startEditing(Map<String, dynamic> message) {
    setState(() { _editingMessageId = message['id']; _messageController.text = message['content'] ?? ''; });
  }

  void _showError(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    if (_messagesStream == null || _isLoadingInfo) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leadingWidth: 30,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Row(children: [
          const CircleAvatar(backgroundColor: Colors.grey, child: Icon(Icons.person, color: Colors.white, size: 20)),
          const SizedBox(width: 10),
          Expanded(child: Text(_chatTitle, style: const TextStyle(fontSize: 16))),
        ]),
        actions: [IconButton(icon: const Icon(Icons.more_vert), onPressed: (){})],
      ),
      body: Container(
        // IMAGEM DE FUNDO AQUI
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/background.jpg'), 
            fit: BoxFit.cover,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _messagesStream,
                builder: (context, snapshot) {
                  var messages = snapshot.data ?? [];
                  messages.addAll(_pendingMessages);
                  messages.sort((a, b) => (a['created_at']??'').compareTo(b['created_at']??''));
                  
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final m = messages[index];
                      if (_deletedMessageIds.contains(m['id'])) return const SizedBox.shrink();

                      final isMine = m['sender_id'] == meuUserId;
                      final content = m['content'] ?? '';
                      final type = m['type'] ?? 'text';
                      final time = DateTime.tryParse(m['created_at'].toString());
                      final timeStr = time != null ? "${time.hour.toString().padLeft(2,'0')}:${time.minute.toString().padLeft(2,'0')}" : "";

                      // Correção Visual do Balão
                      return Align(
                        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.80),
                          child: Card(
                            elevation: 1,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(10),
                                topRight: const Radius.circular(10),
                                bottomLeft: isMine ? const Radius.circular(10) : Radius.zero,
                                bottomRight: isMine ? Radius.zero : const Radius.circular(10),
                              )
                            ),
                            // Cores dos balões (Verde enviado, Cinza recebido)
                            color: isMine ? const Color(0xFF005C4B) : const Color(0xFF1F2C34),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8, right: 8, top: 6, bottom: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (type == 'image') 
                                    Padding(padding: const EdgeInsets.only(bottom: 4), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(content)))
                                  else if (type == 'audio')
                                    Row(mainAxisSize: MainAxisSize.min, children: [
                                      IconButton(icon: Icon(_playingMessageId == m['id'] ? Icons.pause : Icons.play_arrow), onPressed: () => _playAudio(content, m['id'])),
                                      const Text("Áudio", style: TextStyle(color: Colors.white70))
                                    ])
                                  else 
                                    Padding(
                                      padding: const EdgeInsets.only(right: 10, bottom: 0), 
                                      child: Text(content, style: const TextStyle(fontSize: 16, color: Colors.white)),
                                    ),

                                  // Hora e Check (Alinhado à direita)
                                  Align(
                                    alignment: Alignment.bottomRight,
                                    widthFactor: 1.0,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                                        if (isMine) ...[
                                          const SizedBox(width: 4),
                                          const Icon(Icons.done_all, size: 15, color: Colors.blue),
                                        ]
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            // BARRA DE INPUT
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.all(6),
                // Remover cor de fundo para o papel de parede aparecer atrás
                child: Row(children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(color: const Color(0xFF1F2C34), borderRadius: BorderRadius.circular(30)),
                      child: Row(children: [
                        IconButton(icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.grey), onPressed: (){}),
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(hintText: 'Mensagem', border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 10)),
                            minLines: 1, maxLines: 5,
                            onChanged: (t) => setState((){}),
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.attach_file, color: Colors.grey), onPressed: (){
                           showModalBottomSheet(context: context, builder: (c) => Container(height: 100, color: const Color(0xFF1F2C34), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              IconButton(icon: const Icon(Icons.image, color: Colors.purple, size: 40), onPressed: (){ Navigator.pop(c); _enviarImagem(); }),
                              const SizedBox(width: 30),
                              IconButton(icon: const Icon(Icons.insert_drive_file, color: Colors.indigo, size: 40), onPressed: (){ Navigator.pop(c); _enviarArquivoLeve(); }),
                           ])));
                        }),
                        if (_messageController.text.isEmpty) IconButton(icon: const Icon(Icons.camera_alt, color: Colors.grey), onPressed: _enviarImagem),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onLongPress: _startRecording, onLongPressUp: _stopRecordingAndSend,
                    child: CircleAvatar(radius: 24, backgroundColor: const Color(0xFF00A884), child: Icon(_isRecording ? Icons.stop : (_messageController.text.isEmpty ? Icons.mic : Icons.send), color: Colors.white)),
                    onTap: () { if (_messageController.text.isNotEmpty) _enviarMensagem(); },
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

class _EmojiPickerSheet extends StatelessWidget {
  final List<String> emojis = ['👍', '❤️', '😂', '😮', '😢', '👏', '🔥'];
  @override
  Widget build(BuildContext context) {
    return Container(padding: const EdgeInsets.all(16), height: 100, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: emojis.length, separatorBuilder: (_,__)=>const SizedBox(width: 20), itemBuilder: (c, i) => GestureDetector(onTap: ()=>Navigator.pop(c, emojis[i]), child: Text(emojis[i], style: const TextStyle(fontSize: 30)))));
  }
}