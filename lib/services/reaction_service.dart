import 'package:chat_app/services/supabase_service.dart';

class ReactionService {
  static Future<void> toggleReaction({
    required String messageId,
    required String userId,
    required String emoji,
  }) async {
    try {
      final existing = await supabase
          .from('reactions')
          .select()
          .match({
            'message_id': messageId,
            'user_id': userId,
            'emoji': emoji,
          });

      if (existing != null && (existing as List).isNotEmpty) {
        await supabase
            .from('reactions')
            .delete()
            .match({'message_id': messageId, 'user_id': userId, 'emoji': emoji});
      } else {
        await supabase.from('reactions').insert({
          'message_id': messageId,
          'user_id': userId,
          'emoji': emoji,
        });
      }
    } catch (e) {
      rethrow;
    }
  }

  static Future<List<Map<String, dynamic>>> getReactionsForMessage(String messageId) async {
    final rows = await supabase.from('reactions').select('emoji').eq('message_id', messageId);
    if (rows == null) return [];

    final Map<String, int> agg = {};
    for (var r in rows) {
      final e = (r['emoji'] ?? '').toString();
      if (e.isEmpty) continue;
      agg[e] = (agg[e] ?? 0) + 1;
    }

    final List<Map<String, dynamic>> result = agg.entries
        .map((entry) => {'emoji': entry.key, 'count': entry.value})
        .toList(growable: false);

    result.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

    return result;
  }
}
