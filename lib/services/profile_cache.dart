// lib/services/profile_cache.dart
import 'package:chat_app/main.dart'; // Importa o 'supabase' global de main.dart

class ProfileCache {
  static final Map<String, Map<String, dynamic>> cachedProfiles = {};

  /// Retorna { 'name': ..., 'avatar_url': ..., 'show_online_status': ...} ou null.
  static Future<Map<String, dynamic>?> getProfile(String id) async {
    if (cachedProfiles.containsKey(id)) return cachedProfiles[id];

    // 🟢 ATUALIZADO: Seleciona a nova coluna 'show_online_status'
    final res = await supabase
        .from('profiles')
        .select('name, avatar_url, show_online_status')
        .eq('id', id)
        .maybeSingle();

    if (res != null) cachedProfiles[id] = Map<String, dynamic>.from(res);
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  static void setProfile(String id, Map<String, dynamic> profile) {
    cachedProfiles[id] = profile;
  }

  static void clear() => cachedProfiles.clear();
}