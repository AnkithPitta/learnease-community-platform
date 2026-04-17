import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// API Configuration - Automatically selects correct backend URL
/// based on environment (development, production, etc.)
class ApiConfig {
  // ✅ Production server deployed on Render.com
  // Backend API: https://learnease-community-platform.onrender.com
  // MongoDB: Connected and persistent
  // Users: 8 migrated users ready
  static const String _productionBaseUrl = 'https://learnease-community-platform.onrender.com';
  
  // Development/Local URLs
  // Use IPv4 loopback explicitly to avoid IPv6 localhost (::1) issues in browsers
  // when the server is bound to IPv4 only.
  static const String _developmentBaseUrl = 'http://127.0.0.1:8081';

  static String _envBaseUrl() {
    try {
      final v = dotenv.env['API_BASE_URL'];
      if (v == null) return '';
      final trimmed = v.trim();

      // If the override uses localhost, normalize to IPv4 loopback for Flutter Web.
      // This prevents "ClientException: Failed to fetch" when localhost resolves to ::1.
      try {
        final uri = Uri.parse(trimmed);
        if (uri.hasScheme && uri.host == 'localhost') {
          return uri.replace(host: '127.0.0.1').toString();
        }
      } catch (_) {
        // If it's not a valid URI, just return raw string.
      }

      return trimmed;
    } catch (_) {
      return '';
    }
  }
  
  /// Get the appropriate base URL based on environment
  static String get baseUrl {
    // Use local backend in debug mode, production otherwise
    if (kDebugMode) {
      final envUrl = _envBaseUrl();
      if (envUrl.isNotEmpty) return envUrl;
      return _developmentBaseUrl;
    }
    return _productionBaseUrl;
  }
  
  /// Alternative: Check if running on web (Firebase)
  /// Returns production URL for web deployment
  /// ALWAYS returns production for consistency with baseUrl
  static String get webBaseUrl {
    // Use local backend in debug mode, production otherwise
    if (kDebugMode) {
      final envUrl = _envBaseUrl();
      if (envUrl.isNotEmpty) return envUrl;
      return _developmentBaseUrl;
    }
    return _productionBaseUrl;
  }
  
  /// Health check endpoint
  static String get healthCheck => '$baseUrl/health';
  
  /// Validate if production URL is properly configured
  static bool get isProductionConfigured {
    return _productionBaseUrl != 'https://api.learnease.com' &&
           !_productionBaseUrl.contains('ngrok') &&
           _productionBaseUrl.startsWith('https://');
  }
}

