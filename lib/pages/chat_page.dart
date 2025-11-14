// lib/pages/chat_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chat_app/main.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_conversaId != null) return;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args == null) return;

    _conversaId = args as String;
    _messagesStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', _conversaId!)
        .order('created_at', ascending: true);
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _getSenderProfileCached(String senderId) =>
      ProfileCache.getProfile(senderId);

  /// ✉️ Envia mensagem de texto
  Future<void> _enviarMensagem() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _conversaId == null) return;

    try {
      final meuUserId = supabase.auth.currentUser!.id;
      await supabase.from('messages').insert({
        'sender_id': meuUserId,
        'conversation_id': _conversaId,
        'content': content,
      });
      _messageController.clear();
    } catch (error) {
      _showError('Erro ao enviar mensagem: $error');
    }
  }

  /// 🖼️ Envia imagem via Edge Function — compatível com Web
  Future<void> _enviarImagem() async {
    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
      );
      if (pickedFile == null || _conversaId == null) return;

      // ✅ Lê bytes diretamente — funciona em Android, iOS e Web
      final fileBytes = await pickedFile.readAsBytes();
      final fileName = pickedFile.name;

      // 1️⃣ Solicita URL assinada à Edge Function
      final res = await http.post(
        Uri.parse(
          'https://ebuybhhxytldczejyxey.supabase.co/functions/v1/get-signed-upload',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': fileName,
          'mime': 'image/jpeg',
        }),
      );

      if (res.statusCode != 200) {
        throw 'Falha ao gerar URL de upload (${res.statusCode})';
      }

      final data = jsonDecode(res.body);
      final uploadUrl = data['uploadUrl'];
      final key = data['key'];

      // 2️⃣ Faz upload da imagem
      final uploadRes = await http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'image/jpeg'},
        body: fileBytes,
      );

      if (uploadRes.statusCode != 200 && uploadRes.statusCode != 201) {
        throw 'Erro ao enviar imagem (${uploadRes.statusCode})';
      }

      // 3️⃣ Monta a URL pública correta
      final baseUrl =
          'https://ebuybhhxytldczejyxey.supabase.co/storage/v1/object/public/chat_media/$key';
      final finalUrl = '$baseUrl?t=${DateTime.now().millisecondsSinceEpoch}';

      print('✅ Upload completo: $finalUrl');

      // 4️⃣ Envia mensagem com o link da imagem
      final meuUserId = supabase.auth.currentUser!.id;
      await supabase.from('messages').insert({
        'sender_id': meuUserId,
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meuUserId = supabase.auth.currentUser?.id;

    if (_messagesStream == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _conversaId != null ? 'Chat (${_conversaId!.substring(0, 4)}...)' : 'Chat',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.image),
            tooltip: 'Enviar imagem',
            onPressed: _enviarImagem,
          ),
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
                return ListView.builder(
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final senderId = message['sender_id'] as String?;
                    final isMine = senderId == meuUserId;
                    final isMedia = (message['is_media'] ?? false) == true;
                    final content = message['content'] ?? '';

                    return FutureBuilder<Map<String, dynamic>?>(
                      future: _getSenderProfileCached(senderId ?? ''),
                      builder: (context, profileSnapshot) {
                        final senderName = profileSnapshot.data?['name'] ?? '...';
                        final avatarUrl = profileSnapshot.data?['avatar_url'] as String?;

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                            children: [
                              // avatar só quando não for minha mensagem
                              if (!isMine)
                                CircleAvatar(
                                  radius: 18,
                                  backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                  child: avatarUrl == null ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?') : null,
                                ),
                              if (!isMine) const SizedBox(width: 8),

                              // balão
                              Flexible(
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
                                      const SizedBox(height: 4),
                                      if (isMedia)
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 220,
                                              maxHeight: 220,
                                            ),
                                            child: Image.network(
                                              content,
                                              fit: BoxFit.cover,
                                              headers: const {
                                                "Cache-Control": "no-cache",
                                                "Pragma": "no-cache",
                                              },
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
                                        Text(
                                          content,
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                    ],
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
