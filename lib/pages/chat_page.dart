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

    // Ao entrar no chat, marca online e typing null
    if (meuUserId != null) {
      PresenceService.setOnline(meuUserId!);
      PresenceService.setTyping(meuUserId!, null);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    if (meuUserId != null) {
      PresenceService.setTyping(meuUserId!, null);
      // não setamos offline aqui porque usuário pode navegar entre telas
    }
    super.dispose();
  }

  Future<Map<String, dynamic>?> _getSenderProfileCached(String senderId) =>
      ProfileCache.getProfile(senderId);

  /// Envia mensagem de texto
  Future<void> _enviarMensagem() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _conversaId == null) return;
    try {
      final id = supabase.auth.currentUser!.id;
      await supabase.from('messages').insert({
        'sender_id': id,
        'conversation_id': _conversaId,
        'content': content,
      });
      _messageController.clear();
      TypingService.stopTypingNow(userId: id);
      PresenceService.setTyping(id, null);
    } catch (error) {
      _showError('Erro ao enviar mensagem: $error');
    }
  }

  /// Envia imagem via Edge Function
  Future<void> _enviarImagem() async {
    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (pickedFile == null || _conversaId == null) return;

      final fileBytes = await pickedFile.readAsBytes();
      final fileName = pickedFile.name;

      final res = await http.post(
        Uri.parse('https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': fileName,
          'mime': 'image/jpeg',
          'folder': 'chat_media',
        }),
      );

      if (res.statusCode != 200) {
        throw 'Falha ao gerar URL de upload (${res.statusCode})';
      }

      final data = jsonDecode(res.body);
      final uploadUrl = data['uploadUrl'];
      final key = data['key'];

      final uploadRes = await http.put(Uri.parse(uploadUrl), headers: {'Content-Type': 'image/jpeg'}, body: fileBytes);

      if (uploadRes.statusCode != 200 && uploadRes.statusCode != 201) {
        throw 'Erro ao enviar imagem (${uploadRes.statusCode})';
      }

      final baseUrl = 'https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/chat_media/$key';
      final finalUrl = '$baseUrl?t=${DateTime.now().millisecondsSinceEpoch}';

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

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  // Reações: long press para abrir a seleção rápida de emojis (estilo WhatsApp)
  Future<void> _onMessageLongPress(Map<String, dynamic> message) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _EmojiPickerSheet(),
    );
    if (selected == null) return;

    final messageId = message['id'] as String;
    final userId = supabase.auth.currentUser!.id;

    try {
      await ReactionService.toggleReaction(messageId: messageId, userId: userId, emoji: selected);
    } catch (e) {
      _showError('Erro nas reações: $e');
    }
  }

  Widget _buildReactionsRow(String messageId) {
    // Mostra reações agregadas se tiver em cache (o ideal é buscar via view)
    final list = _reactionsCache[messageId] ?? [];
    if (list.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      children: list.map((r) {
        final emoji = r['emoji'] as String? ?? '';
        final count = r['count'] ?? 1;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji),
              const SizedBox(width: 4),
              Text(count.toString(), style: const TextStyle(fontSize: 12)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Future<void> _refreshReactions(List<Map<String, dynamic>> messages) async {
    // atualiza cache de reações para as mensagens visíveis
    for (var m in messages) {
      final mid = m['id'] as String;
      final rows = await supabase.from('reactions').select('emoji, user_id').eq('message_id', mid);
      // agregação simples
      final agg = <String, int>{};
      if (rows != null) {
        for (var r in rows) {
          final e = r['emoji'] as String? ?? '';
          agg[e] = (agg[e] ?? 0) + 1;
        }
      }
      final list = agg.entries.map((e) => {'emoji': e.key, 'count': e.value}).toList();
      _reactionsCache[mid] = list;
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

    if (_messagesStream == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_conversaId != null ? 'Chat (${_conversaId!.substring(0, 6)})' : 'Chat'),
        actions: [
          IconButton(icon: const Icon(Icons.image), tooltip: 'Enviar imagem', onPressed: _enviarImagem),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Erro: ${snapshot.error}'));
                }
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const Center(child: Text('Nenhuma mensagem ainda.'));
                }

                final messages = snapshot.data!;
                // atualiza reações simples
                _refreshReactions(messages);

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final senderId = message['sender_id'] as String?;
                    final isMine = senderId == meuUserIdLocal;
                    final isMedia = (message['is_media'] ?? false) == true;
                    final content = message['content'] ?? '';

                    return FutureBuilder<Map<String, dynamic>?>(
                      future: _getSenderProfileCached(senderId ?? ''),
                      builder: (context, profileSnapshot) {
                        final senderName = profileSnapshot.data?['name'] ?? '...';
                        final avatarUrl = profileSnapshot.data?['avatar_url'] as String?;

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                          child: Row(
                            mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isMine)
                                CircleAvatar(
                                  radius: 18,
                                  backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                  child: avatarUrl == null ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?') : null,
                                ),
                              if (!isMine) const SizedBox(width: 8),
                              Flexible(
                                child: GestureDetector(
                                  onLongPress: () => _onMessageLongPress(message),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isMine ? Colors.blue : Colors.grey.shade700,
                                      borderRadius: BorderRadius.circular(15),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          isMine ? 'Você' : senderName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        if (isMedia)
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(12),
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220),
                                              child: Image.network(
                                                content,
                                                fit: BoxFit.cover,
                                                headers: const {"Cache-Control": "no-cache", "Pragma": "no-cache"},
                                                loadingBuilder: (context, child, progress) {
                                                  if (progress == null) return child;
                                                  return const Center(child: CircularProgressIndicator());
                                                },
                                                errorBuilder: (context, error, stackTrace) {
                                                  return Container(
                                                    width: 220,
                                                    height: 220,
                                                    color: Colors.black26,
                                                    child: const Icon(Icons.broken_image, size: 64, color: Colors.white),
                                                  );
                                                },
                                              ),
                                            ),
                                          )
                                        else
                                          Text(content, style: const TextStyle(color: Colors.white)),
                                        const SizedBox(height: 6),
                                        _buildReactionsRow(message['id'] as String),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Digite uma mensagem...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(12),
                      ),
                      onChanged: _onTextChanged,
                      onFieldSubmitted: (_) => _enviarMensagem(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _enviarMensagem,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
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
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Wrap(
        spacing: 12,
        children: emojis
            .map((e) => GestureDetector(
                  onTap: () => Navigator.of(context).pop(e),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                    child: Text(e, style: const TextStyle(fontSize: 26)),
                  ),
                ))
            .toList(),
      ),
    );
  }
}
