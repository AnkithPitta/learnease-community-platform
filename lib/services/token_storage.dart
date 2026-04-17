import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Simple token storage helper using `SharedPreferences`.
///
/// Saves `access_token` and `refresh_token`, provides helpers
/// to read them, clear them, and check access token expiry
/// by decoding the JWT `exp` claim (no signature verification).
class TokenStorage {
  TokenStorage._();

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';

  /// Save both access and refresh tokens.
  static Future<void> saveTokens(String accessToken, String refreshToken) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessKey, accessToken);
    await prefs.setString(_refreshKey, refreshToken);
  }

  /// Save only access token.
  static Future<void> saveAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessKey, token);
  }

  /// Retrieve access token or null if not present.
  static Future<String?> getAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accessKey);
  }

  /// Retrieve refresh token or null if not present.
  static Future<String?> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshKey);
  }

  /// Remove both tokens (logout).
  static Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessKey);
    await prefs.remove(_refreshKey);
  }

  /// Returns a map with `Authorization` header if access token exists.
  /// Example: { 'Authorization': 'Bearer <token>' }
  static Future<Map<String, String>> authHeaders() async {
    final token = await getAccessToken();
    if (token == null) return <String, String>{};
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  /// Quick check whether the access token appears unexpired.
  /// Decodes the JWT payload and checks `exp` claim (seconds since epoch).
  /// Note: This does NOT verify signature; use server validation for security.
  static Future<bool> hasValidAccessToken() async {
    final token = await getAccessToken();
    if (token == null || token.trim().isEmpty) return false;

    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final payload = parts[1];
      // Base64Url decode with padding
      String normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      if (!map.containsKey('exp')) return true; // no exp claim -> assume valid
      final exp = map['exp'];
      int expSeconds;
      if (exp is int) {
        expSeconds = exp;
      } else if (exp is String) {
        expSeconds = int.tryParse(exp) ?? 0;
      } else if (exp is double) {
        expSeconds = exp.toInt();
      } else {
        return false;
      }

      final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return expSeconds > nowSeconds;
    } catch (_) {
      // If anything fails, be conservative and treat token as invalid
      return false;
    }
  }
}
