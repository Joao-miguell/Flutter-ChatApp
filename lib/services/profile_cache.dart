// lib/services/profile_cache.dart
import 'package:chat_app/main.dart'; // Importa o 'supabase' global de main.dart

class ProfileCache {
  // 🟢 CORREÇÃO: Renomeado de '_cache' (privado) para 'cachedProfiles' (público)
  static final Map<String, Map<String, dynamic>> cachedProfiles = {};

  /// Retorna { 'name': ..., 'avatar_url': ... } ou null.
  static Future<Map<String, dynamic>?> getProfile(String id) async {
    // 🟢 CORREÇÃO: Usa 'cachedProfiles'
    if (cachedProfiles.containsKey(id)) return cachedProfiles[id];

    final res = await supabase
        .from('profiles')
        .select('name, avatar_url')
        .eq('id', id)
        .maybeSingle();

    // 🟢 CORREÇÃO: Usa 'cachedProfiles'
    if (res != null) cachedProfiles[id] = Map<String, dynamic>.from(res);
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  static void setProfile(String id, Map<String, dynamic> profile) {
    // 🟢 CORREÇÃO: Usa 'cachedProfiles'
    cachedProfiles[id] = profile;
  }

  // 🟢 CORREÇÃO: Usa 'cachedProfiles'
  static void clear() => cachedProfiles.clear();
}