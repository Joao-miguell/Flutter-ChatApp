import 'dart:async';
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/profile_cache.dart';

class PresenceService {
  static Stream<List<Map<String, dynamic>>> presenceStream({String? conversationId}) {
    return supabase
        .from('user_presence')
        .stream(primaryKey: ['user_id'])
        .order('updated_at', ascending: true);
  }

  static Future<void> setOnline(String userId) async {
    try {
      final profile = await ProfileCache.getProfile(userId);
      final shouldShow = profile?['show_online_status'] ?? true;

      if (!shouldShow) {
        await setOffline(userId);
        return;
      }

      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'is_online': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  static Future<void> setOffline(String userId) async {
    try {
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'is_online': false,
        'typing_conversation': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      await supabase
          .from('profiles')
          .update({
            'is_online': false,
            'last_seen': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
    } catch (_) {}
  }

  static Future<void> setTyping(String userId, String? conversationId) async {
    try {
      await supabase.from('user_presence').upsert({
        'user_id': userId,
        'typing_conversation': conversationId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> fetchPresence(String userId) async {
    final res = await supabase.from('user_presence').select().eq('user_id', userId).maybeSingle();
    if (res == null) return null;
    return Map<String, dynamic>.from(res);
  }
}
