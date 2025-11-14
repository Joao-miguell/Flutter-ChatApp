// lib/services/profile_cache.dart
import 'package:chat_app/main.dart';

class ProfileCache {
  static final Map<String, Map<String, dynamic>> _cache = {};

  /// Retorna { 'name': ..., 'avatar_url': ... } ou null.
  static Future<Map<String, dynamic>?> getProfile(String id) async {
    if (_cache.containsKey(id)) return _cache[id];

    final res = await supabase
        .from('profiles')
        .select('name, avatar_url')
        .eq('id', id)
        .maybeSingle();

    if (res != null) _cache[id] = Map<String, dynamic>.from(res);
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  static void setProfile(String id, Map<String, dynamic> profile) {
    _cache[id] = profile;
  }

  static void clear() => _cache.clear();
}
