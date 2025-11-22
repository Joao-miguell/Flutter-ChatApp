// lib/pages/call_page.dart
import 'package:flutter/material.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'dart:math';

class CallPage extends StatelessWidget {
  final String callID;
  final String userID;
  final String userName;
  final bool isVideo;

  const CallPage({
    super.key,
    required this.callID,
    required this.userID,
    required this.userName,
    this.isVideo = true,
  });

  @override
  Widget build(BuildContext context) {
    return ZegoUIKitPrebuiltCall(
      appID: 123456789, // 🔴 VOCÊ PRECISA DO SEU APP ID DO CONSOLE ZEGO (https://console.zegocloud.com/)
      appSign: 'COLE_SEU_APP_SIGN_AQUI', // 🔴 VOCÊ PRECISA DO SEU APP SIGN
      userID: userID,
      userName: userName,
      callID: callID,
      config: isVideo 
          ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
          : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall(),
    );
  }
}