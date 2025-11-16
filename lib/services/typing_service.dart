// lib/services/typing_service.dart
import 'dart:async';
import 'package:chat_app/services/supabase_service.dart';
import 'package:chat_app/services/presence_service.dart';

class TypingService {
  static Timer? _typingTimer;

  /// Deve ser chamado quando o campo de texto mudar.
  /// Ele define que o usuário está digitando e depois, após [timeoutSeconds],
  /// limpa o estado de typing automaticamente.
  static void notifyTyping({
    required String conversationId,
    required String userId,
    int timeoutSeconds = 2,
  }) {
    // Define typing
    PresenceService.setTyping(userId, conversationId);

    // Reinicia timer
    _typingTimer?.cancel();
    _typingTimer = Timer(Duration(seconds: timeoutSeconds), () {
      PresenceService.setTyping(userId, null);
    });
  }

  /// Para imediatamente (quando enviar a mensagem ou sair do chat)
  static void stopTypingNow({required String userId}) {
    _typingTimer?.cancel();
    PresenceService.setTyping(userId, null);
  }
}
