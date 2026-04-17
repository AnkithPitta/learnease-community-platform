import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class OpenAIChatService {
  final String apiKey;
  final String model;
  final Uri endpoint;
  final Duration timeout;

  OpenAIChatService({
    required this.apiKey,
    required this.model,
    Uri? endpoint,
    Duration? timeout,
  })  : endpoint = endpoint ?? Uri.parse('https://api.openai.com/v1/chat/completions'),
        timeout = timeout ?? const Duration(seconds: 20);

  factory OpenAIChatService.fromEnv() {
    String safeEnv(String key, [String fallback = '']) {
      try {
        final v = dotenv.env[key];
        if (v == null || v.trim().isEmpty) return fallback;
        return v.trim();
      } catch (_) {
        return fallback;
      }
    }

    final apiKey = safeEnv('OPENAI_API_KEY');
    final model = safeEnv('OPENAI_MODEL', 'gpt-4o-mini');
    final timeoutMs = int.tryParse(safeEnv('OPENAI_TIMEOUT_MS', '20000')) ?? 20000;
    final endpoint = safeEnv('OPENAI_API_BASE', 'https://api.openai.com/v1/chat/completions');
    return OpenAIChatService(
      apiKey: apiKey,
      model: model,
      endpoint: Uri.parse(endpoint),
      timeout: Duration(milliseconds: timeoutMs),
    );
  }

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<String> getReply({
    required List<Map<String, String>> messages,
    double temperature = 0.4,
  }) async {
    if (!isConfigured) {
      throw StateError('OPENAI_API_KEY is missing. Add it to .env (not committed).');
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
    };

    final resp = await http
        .post(
          endpoint,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      if (kDebugMode) {
        debugPrint('OpenAI error ${resp.statusCode}: ${resp.body}');
      }
      throw http.ClientException('OpenAI error: ${resp.statusCode}');
    }

    final decoded = jsonDecode(resp.body);
    final content = decoded is Map
        ? decoded['choices']?[0]?['message']?['content']
        : null;
    final text = content?.toString().trim();
    if (text == null || text.isEmpty) return 'I couldn\'t generate a response. Please try again.';
    return text;
  }
}
