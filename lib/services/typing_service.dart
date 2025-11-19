import 'dart:async';
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/presence_service.dart';

class TypingService {
  static Timer? _typingTimer;

  static void notifyTyping({
    required String conversationId,
    required String userId,
    int timeoutSeconds = 2,
  }) {
    PresenceService.setTyping(userId, conversationId);

    _typingTimer?.cancel();
    _typingTimer = Timer(Duration(seconds: timeoutSeconds), () {
      PresenceService.setTyping(userId, null);
    });
  }

  static void stopTypingNow({required String userId}) {
    _typingTimer?.cancel();
    PresenceService.setTyping(userId, null);
  }
}
