// lib/pages/chat_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/presence_service.dart';
import 'package:chat_app/services/typing_service.dart';
import 'package:chat_app/services/reaction_service.dart';
import 'package:chat_app/services/profile_cache.dart';
// 🟢 IMPORTANTE: Adicione uuid no pubspec.yaml se não tiver, ou use DateTime para ID temporário simples
// Para simplificar aqui, usaremos DateTime como ID temporário.

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
  Timer? _typingTimer;
  String? meuUserId;
  Map<String, List<Map<String, dynamic>>> _reactionsCache = {};

  StreamSubscription? _presenceSubscription;
  final Map<String, String> _typingUsers = {}; 
  bool _isGroup = false;
  bool _isLoadingInfo = true;
  String _chatTitle = 'Carregando...';

  String? _editingMessageId; 
  bool get _isEditing => _editingMessageId != null;

  // Listas para otimização visual (Instantaneidade)
  final List<String> _deletedMessageIds = []; // Mensagens que o usuário apagou
  final List<Map<String, dynamic>> _pendingMessages = []; // 🟢 Mensagens sendo enviadas

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

  Future<void> _loadChatDetails() async {
    if (_conversaId == null || meuUserId == null) return;
    try {
      final data = await supabase
          .from('conversations')
          .select('is_group, name')
          .eq('id', _conversaId!)
          .single();
      
      final isGroup = data['is_group'] ?? false;
      String displayTitle = data['name'] ?? 'Chat';

      if (!isGroup) {
        final otherParticipant = await supabase
            .from('participants')
            .select('user_id')
            .eq('conversation_id', _conversaId!)
            .neq('user_id', meuUserId!)
            .maybeSingle();
        
        if (otherParticipant != null) {
          final otherId = otherParticipant['user_id'] as String;
          final profile = await ProfileCache.getProfile(otherId);
          if (profile != null) {
            displayTitle = profile['name'] ?? 'Usuário';
          }
        }
      }

      if (mounted) {
        setState(() {
          _isGroup = isGroup;
          _chatTitle = displayTitle;
          _isLoadingInfo = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingInfo = false);
    }
  }

  void _listenToPresence() {
    _cacheParticipantsProfiles();
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
      if (newTypingUsers.keys.length != _typingUsers.keys.length ||
          !newTypingUsers.keys.every((k) => _typingUsers.containsKey(k))) {
        if (mounted) {
          setState(() {
            _typingUsers.clear();
            _typingUsers.addAll(newTypingUsers);
          });
        }
      }
    });
  }

  Future<void> _cacheParticipantsProfiles() async {
    if (_conversaId == null) return;
    try {
      final participants = await supabase.from('participants').select('user_id').eq('conversation_id', _conversaId!);
      for (var p in participants) {
        final userId = p['user_id'] as String?;
        if (userId != null) await ProfileCache.getProfile(userId);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _messageController.dispose();
    _presenceSubscription?.cancel();
    if (meuUserId != null) PresenceService.setTyping(meuUserId!, null);
    super.dispose();
  }

  Future<Map<String, dynamic>?> _getSenderProfileCached(String senderId) => ProfileCache.getProfile(senderId);

  Future<void> _enviarMensagem() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _conversaId == null) return;
    
    final id = supabase.auth.currentUser!.id;

    if (_isEditing) {
      // Edição não precisa ser otimista visualmente, pois é rápida
      try {
        await supabase.from('messages').update({
          'content': content,
          'is_edited': true,
        }).eq('id', _editingMessageId!);
        setState(() {
          _editingMessageId = null;
          _messageController.clear();
        });
      } catch (e) {
        _showError('Erro ao editar: $e');
      }
    } else {
      // 🟢 ENVIO OTIMISTA 🟢
      final tempId = 'temp-${DateTime.now().millisecondsSinceEpoch}';
      final tempMessage = {
        'id': tempId,
        'sender_id': id,
        'conversation_id': _conversaId,
        'content': content,
        'created_at': DateTime.now().toIso8601String(),
        'is_media': false,
        'is_edited': false,
        'status': 'sending' // Marcador local
      };

      setState(() {
        _pendingMessages.add(tempMessage);
        _messageController.clear();
      });

      try {
        await supabase.from('messages').insert({
          'sender_id': id,
          'conversation_id': _conversaId,
          'content': content,
        });
        
        // Sucesso: remove a mensagem temporária (o stream trará a real)
        if (mounted) {
          setState(() {
            _pendingMessages.removeWhere((m) => m['id'] == tempId);
          });
        }
        
        TypingService.stopTypingNow(userId: id);
        PresenceService.setTyping(id, null);

      } catch (error) {
        // Erro: remove a temporária e avisa
        if (mounted) {
          setState(() {
            _pendingMessages.removeWhere((m) => m['id'] == tempId);
          });
          _messageController.text = content; // Devolve o texto para o campo
        }
        _showError('Erro ao enviar: $error');
      }
    }
  }

  Future<void> _enviarImagem() async {
    // Para imagem, é mais complexo fazer otimista sem mostrar o upload progress
    // Vamos manter o padrão por enquanto.
    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (pickedFile == null || _conversaId == null) return;

      final fileBytes = await pickedFile.readAsBytes();
      final fileName = pickedFile.name;

      final res = await http.post(
        Uri.parse('https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'filename': fileName, 'mime': 'image/jpeg', 'folder': 'chat_media'}),
      );

      if (res.statusCode != 200) throw 'Falha ao gerar URL';
      final data = jsonDecode(res.body);
      final key = data['key'];
      final uploadRes = await http.put(Uri.parse(data['uploadUrl']), headers: {'Content-Type': 'image/jpeg'}, body: fileBytes);
      if (uploadRes.statusCode != 200 && uploadRes.statusCode != 201) throw 'Erro ao enviar imagem';

      final finalUrl = 'https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/chat_media/$key?t=${DateTime.now().millisecondsSinceEpoch}';

      final meuId = supabase.auth.currentUser!.id;
      await supabase.from('messages').insert({
        'sender_id': meuId,
        'conversation_id': _conversaId,
        'content': finalUrl,
        'is_media': true,
      });
    } catch (error) {
      _showError('Erro ao enviar imagem: $error');
    }
  }

  Future<void> _confirmDelete(String messageId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar mensagem?'),
        content: const Text('Essa ação não pode ser desfeita.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('Apagar')),
        ],
      ),
    );

    if (confirm == true) {
      setState(() { _deletedMessageIds.add(messageId); });
      try {
        await supabase.from('messages').delete().eq('id', messageId);
      } catch (e) {
        setState(() { _deletedMessageIds.remove(messageId); });
        _showError('Erro ao apagar: $e');
      }
    }
  }

  void _startEditing(Map<String, dynamic> message) {
    setState(() {
      _editingMessageId = message['id'];
      _messageController.text = message['content'] ?? '';
    });
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _messageController.clear();
    });
  }

  Future<void> _onMessageLongPress(Map<String, dynamic> message) async {
    final senderId = message['sender_id'] as String?;
    final isMine = senderId == meuUserId;
    final isMedia = message['is_media'] == true;

    if (!isMine) {
      final selected = await showModalBottomSheet<String>(context: context, builder: (_) => _EmojiPickerSheet());
      if (selected != null) {
        try {
          await ReactionService.toggleReaction(messageId: message['id'], userId: meuUserId!, emoji: selected);
        } catch (e) { _showError('Erro: $e'); }
      }
      return;
    }

    final createdAt = DateTime.tryParse(message['created_at'] ?? '');
    bool canEdit = false;
    if (createdAt != null && !isMedia) {
      canEdit = DateTime.now().toUtc().difference(createdAt.toUtc()).inMinutes < 15;
    }

    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canEdit)
              ListTile(leading: const Icon(Icons.edit), title: const Text('Editar'), onTap: () { Navigator.pop(ctx); _startEditing(message); }),
            ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: const Text('Apagar', style: TextStyle(color: Colors.red)), onTap: () { Navigator.pop(ctx); _confirmDelete(message['id']); }),
          ],
        ),
      )
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Widget _buildReactionsRow(String messageId) {
    final list = _reactionsCache[messageId] ?? [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, children: list.map((r) => Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text(r['emoji'] ?? ''), const SizedBox(width: 4), Text(r['count'].toString(), style: const TextStyle(fontSize: 12))]))).toList());
  }

  Future<void> _refreshReactions(List<Map<String, dynamic>> messages) async {
    if (!mounted) return;
    for (var m in messages) {
      final mid = m['id'] as String;
      if (mid.startsWith('temp-')) continue; // Ignora mensagens temporárias
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

  void _onTextChanged(String text) {
    final uid = supabase.auth.currentUser!.id;
    if (_conversaId == null) return;
    TypingService.notifyTyping(conversationId: _conversaId!, userId: uid);
  }

  @override
  Widget build(BuildContext context) {
    final meuUserIdLocal = supabase.auth.currentUser?.id;

    if (_messagesStream == null || _isLoadingInfo) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: _isGroup 
            ? Text(_chatTitle) 
            : StreamBuilder(
                stream: PresenceService.presenceStream(),
                builder: (context, snapshot) {
                  String subtitle = '';
                  if (snapshot.hasData) {
                    final isSomeoneOnline = snapshot.data!.any((s) => s['user_id'] != meuUserId && (s['is_online'] ?? false));
                    if (isSomeoneOnline) subtitle = 'Online'; else if (snapshot.data!.isNotEmpty) subtitle = 'Offline';
                  }
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_chatTitle), if (subtitle.isNotEmpty) Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white70))]);
                },
              ),
        actions: [IconButton(icon: const Icon(Icons.image), onPressed: _enviarImagem)],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                // 🟢 COMBINA AS LISTAS: REAIS + PENDENTES 🟢
                var allMessages = <Map<String, dynamic>>[];
                
                if (snapshot.hasData) {
                  allMessages.addAll(snapshot.data!);
                }
                allMessages.addAll(_pendingMessages);

                // Ordena por data
                allMessages.sort((a, b) {
                  final da = DateTime.tryParse(a['created_at'].toString()) ?? DateTime.now();
                  final db = DateTime.tryParse(b['created_at'].toString()) ?? DateTime.now();
                  return da.compareTo(db);
                });

                // Filtra as apagadas
                allMessages = allMessages.where((m) => !_deletedMessageIds.contains(m['id'])).toList();

                if (allMessages.isEmpty) {
                  return const Center(child: Text('Nenhuma mensagem ainda.'));
                }
                
                // Atualiza reações (apenas das mensagens reais)
                if (snapshot.hasData) _refreshReactions(snapshot.data!);

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: allMessages.length,
                  itemBuilder: (context, index) {
                    final message = allMessages[index];
                    final senderId = message['sender_id'] as String?;
                    final isMine = senderId == meuUserIdLocal;
                    final isMedia = (message['is_media'] ?? false) == true;
                    final content = message['content'] ?? '';
                    final isEdited = (message['is_edited'] ?? false) == true;
                    // 🟢 Efeito visual de "enviando"
                    final isSending = message['status'] == 'sending';

                    return FutureBuilder<Map<String, dynamic>?>(
                      future: _getSenderProfileCached(senderId ?? ''),
                      builder: (context, profileSnapshot) {
                        final senderName = profileSnapshot.data?['name'] ?? '...';
                        final avatarUrl = profileSnapshot.data?['avatar_url'] as String?;

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                          child: Opacity(
                            // Deixa a mensagem meio transparente enquanto envia
                            opacity: isSending ? 0.5 : 1.0,
                            child: Row(
                              mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!isMine)
                                  CircleAvatar(radius: 18, backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null, child: avatarUrl == null ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?') : null),
                                if (!isMine) const SizedBox(width: 8),
                                Flexible(
                                  child: GestureDetector(
                                    onLongPress: isSending ? null : () => _onMessageLongPress(message),
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: isMine ? Colors.blue : Colors.grey.shade700,
                                        borderRadius: BorderRadius.circular(15),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(isMine ? 'Você' : senderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white70)),
                                          const SizedBox(height: 6),
                                          if (isMedia)
                                            ClipRRect(borderRadius: BorderRadius.circular(12), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220), child: Image.network(content, fit: BoxFit.cover)))
                                          else
                                            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [Flexible(child: Text(content, style: const TextStyle(color: Colors.white))), if (isEdited) const Padding(padding: EdgeInsets.only(left: 6, top: 4), child: Text('(editado)', style: TextStyle(fontSize: 10, color: Colors.white60, fontStyle: FontStyle.italic)))]),
                                          const SizedBox(height: 6),
                                          _buildReactionsRow(message['id'] as String),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          
          if (_typingUsers.isNotEmpty && !_isGroup)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), child: Row(children: [const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text('${_typingUsers.values.first}${_typingUsers.length > 1 ? ' e outros' : ''} está${_typingUsers.length > 1 ? 'ão' : ''} digitando...', style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.white70))])),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column( 
                children: [
                  if (_isEditing)
                    Container(color: Colors.grey.shade800, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [const Icon(Icons.edit, size: 16, color: Colors.white70), const SizedBox(width: 8), const Text("Editando mensagem", style: TextStyle(color: Colors.white70)), const Spacer(), GestureDetector(onTap: _cancelEditing, child: const Icon(Icons.close, color: Colors.white70))])),
                  Row(children: [Expanded(child: TextFormField(controller: _messageController, decoration: const InputDecoration(hintText: 'Digite uma mensagem...', border: OutlineInputBorder(), contentPadding: EdgeInsets.all(12)), onChanged: _onTextChanged, onFieldSubmitted: (_) => _enviarMensagem())), const SizedBox(width: 8), IconButton(icon: Icon(_isEditing ? Icons.check : Icons.send), onPressed: _enviarMensagem, style: IconButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white, padding: const EdgeInsets.all(12)))])
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmojiPickerSheet extends StatelessWidget {
  final List<String> emojis = ['👍', '❤️', '😂', '😮', '😢', '👏', '🔥'];
  @override
  Widget build(BuildContext context) {
    return Container(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8), child: Wrap(spacing: 12, children: emojis.map((e) => GestureDetector(onTap: () => Navigator.of(context).pop(e), child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)), child: Text(e, style: const TextStyle(fontSize: 26))))).toList()));
  }
}