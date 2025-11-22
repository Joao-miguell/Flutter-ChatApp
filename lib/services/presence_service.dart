import 'package:chat_app/services/profile_cache.dart';
import 'dart:async';
import 'package:chat_app/services/supabase_service.dart';

class PresenceService {
  static Timer? _heartbeatTimer;

  /// Inicia o monitoramento. Deve ser chamado no main.dart
  static void startHeartbeat(String userId) {
    _heartbeatTimer?.cancel();
    // Envia sinal imediatamente
    setOnline(userId);
    // E repete a cada 45 segundos
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 45), (_) async {
      await setOnline(userId);
    });
  }

  static void stopHeartbeat() {
    _heartbeatTimer?.cancel();
  }

  /// Retorna o Stream de presença
  static Stream<List<Map<String, dynamic>>> presenceStream() {
    return supabase
        .from('user_presence')
        .stream(primaryKey: ['user_id'])
        .order('updated_at', ascending: true);
  }

  /// Marca como Online (SÓ SE O USUÁRIO PERMITIR NAS CONFIGURAÇÕES)
  static Future<void> setOnline(String userId) async {
    try {
      // 1. Checa se o usuário quer aparecer online
      final profile = await supabase
          .from('profiles')
          .select('show_online_status')
          .eq('id', userId)
          .maybeSingle();

      final shouldShow = profile?['show_online_status'] ?? true;

      // Se a configuração for "Falso" (Privado), forçamos Offline e paramos por aqui.
      if (!shouldShow) {
        await setOffline(userId);
        return;
      }

      // 2. Se for público, atualiza o banco dizendo "Estou aqui agora"
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'is_online': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  /// Marca como Offline e atualiza o "Visto por último"
  static Future<void> setOffline(String userId) async {
    try {
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'is_online': false,
        'typing_conversation': null, // Para de digitar também
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      // Atualiza o last_seen no perfil
      await supabase.from('profiles').update({
        'is_online': false,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
    } catch (_) {}
  }

  /// Lógica de Digitando
  static Future<void> setTyping(String userId, String? conversationId) async {
    try {
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'typing_conversation': conversationId,
        'updated_at': DateTime.now().toUtc().toIso8601String(), // Também serve como heartbeat
      });
    } catch (_) {}
  }
}