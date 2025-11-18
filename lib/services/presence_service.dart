// lib/services/presence_service.dart
import 'dart:async';
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/profile_cache.dart'; // 🟢 Novo Import

class PresenceService {
  static Stream<List<Map<String, dynamic>>> presenceStream({String? conversationId}) {
    return supabase
        .from('user_presence')
        .stream(primaryKey: ['user_id'])
        .order('updated_at', ascending: true);
  }

  /// 🟢 VERIFICA O CACHE antes de marcar como online
  static Future<void> setOnline(String userId) async {
    try {
      final profile = await ProfileCache.getProfile(userId);
      // Se a opção de ocultar estiver desativada (show_online_status = false), 
      // não marca o usuário como online.
      final shouldShow = profile?['show_online_status'] ?? true; 

      if (!shouldShow) {
        // Se a opção está desativada, garantimos que ele está offline
        await setOffline(userId); 
        return;
      }

      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'is_online': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // silencioso
    }
  }

  /// Marca usuário como offline e atualiza last_seen no profiles
  static Future<void> setOffline(String userId) async {
    try {
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'is_online': false,
        'typing_conversation': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      // Atualiza last_seen no profiles
      await supabase
          .from('profiles')
          .update({
            'is_online': false,
            'last_seen': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
    } catch (_) {
      // silencioso
    }
  }

  /// Marca usuário como digitando em determinada conversa (ou null para parar)
  static Future<void> setTyping(String userId, String? conversationId) async {
    try {
      // 🟢 Opcional: Impedir que envie "digitando" se status online estiver oculto.
      // A setOnline já cuida de manter is_online=false, mas vamos garantir o mínimo de envio.
      
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'typing_conversation': conversationId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // silencioso
    }
  }

  /// Lê presença única (one-shot)
  static Future<Map<String, dynamic>?> fetchPresence(String userId) async {
    final res = await supabase.from('user_presence').select().eq('user_id', userId).maybeSingle();
    if (res == null) return null;
    return Map<String, dynamic>.from(res);
  }
}