import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../config/api_config.dart';

/// AIService (Gemini/proxy-only)
/// Client-side wrapper that posts user messages to a server-side AI proxy.
class AIService {
  final String provider; // always 'gemini' for this app
  final String baseUrl; // proxy base, e.g. http://localhost:8080/api/ai
  final String model; // e.g. 'models/gemini-1'
  final Duration timeout;

  AIService._(this.provider, this.baseUrl, this.model, this.timeout);

  factory AIService.fromEnv() {
    // Safe dotenv reads (dotenv may not be initialized on web builds)
    String safeEnv(String key, [String? fallback]) {
      try {
        final v = dotenv.env[key];
        if (v == null || v.trim().isEmpty) return fallback ?? '';
        return v.trim();
      } catch (_) {
        return fallback ?? '';
      }
    }

    // Always use the app backend as AI proxy.
    // This avoids repeated Flutter Web failures caused by stale AI_* env overrides
    // (e.g. AI_PROXY_BASE=http://127.0.0.1:8080).
    final proxyBase = '${ApiConfig.baseUrl}/api/ai';
    final timeoutMs = int.tryParse(safeEnv('AI_TIMEOUT_MS', '15000')) ?? 15000;
    final model = safeEnv('AI_MODEL', 'models/gemini-1');

    return AIService._('gemini', proxyBase, model, Duration(milliseconds: timeoutMs));
  }

  /// Sends a single user message to the server proxy and returns the assistant reply as text.
  Future<String> sendMessage(String message) async {
    final uri = Uri.parse(baseUrl);
    final body = jsonEncode({'provider': provider, 'model': model, 'input': message});
    if (kDebugMode) {
      debugPrint('[AIService] POST $uri');
    }
    final resp = await http
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(timeout);
    if (kDebugMode) {
      debugPrint('[AIService] status=${resp.statusCode}');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw http.ClientException('Proxy AI error: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is Map && decoded['reply'] != null) return decoded['reply'].toString();
    return resp.body;
  }
}
