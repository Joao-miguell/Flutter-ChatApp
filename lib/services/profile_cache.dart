import 'package:chat_app/main.dart';

class ProfileCache {
  static final Map<String, Map<String, dynamic>> cachedProfiles = {};

  static Future<Map<String, dynamic>?> getProfile(String id) async {
    if (cachedProfiles.containsKey(id)) return cachedProfiles[id];

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
