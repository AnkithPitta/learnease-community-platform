import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:uuid/uuid.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

// In-memory storage (replace with database in production)
// MongoDB connection for contributions
Db? mongoDb;
DbCollection? contribCollection;
DbCollection? quizResultsCollection;
DbCollection? challengeResultsCollection;

// User management collections (persistent in MongoDB)
DbCollection? mongoUsersCollection;
DbCollection? mongoSessionsCollection;
DbCollection? mongoEmailOtpsCollection;
// Simple local env reader (can be used during startup)
String? _readLocalEnvTop(String key, {String? path}) {
  try {
    final filePath = path ?? '.env';
    final f = File(filePath);
    if (!f.existsSync()) return null;
    final lines = f.readAsLinesSync();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final k = trimmed.substring(0, idx).trim();
      var v = trimmed.substring(idx + 1).trim();
      if (v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
      if (k == key) return v;
    }
  } catch (_) {}
  return null;
}

// Convert mongodb+srv URI to standard mongodb URI
String convertMongoDbSrvUri(String uri) {
  if (uri.startsWith('mongodb+srv://')) {
    // Convert mongodb+srv:// to mongodb+srv:// by keeping it as is
    // mongo_dart will handle it, but if not, we need to use a workaround
    // For now, let's try using it directly first
    return uri;
  }
  return uri;
}
// Simple JWT secret (override via .env in production)
final jwtSecret = Platform.environment['JWT_SECRET'] ?? _readLocalEnvTop('JWT_SECRET') ?? 'dev_secret_change_me';
final uuid = Uuid();

// SQLite database handle (users persist here)
late final Database db;
bool dbAvailable = true;
final List<Map<String, dynamic>> usersCache = [];
final List<Map<String, dynamic>> sessionsCache = [];

// Username uniqueness enforcement

void _initDb() {
  try {
    // Use absolute path to ensure database persists in the community_server directory
    // Get the directory where this script is running from
    final scriptDir = File(Platform.script.toFilePath()).parent.parent.path;
    final dbPath = '$scriptDir${Platform.pathSeparator}users.db';
    db = sqlite3.open(dbPath);
    
    print('📂 Database path: $dbPath');
    
    // Create tables if they don't exist
    db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        email TEXT UNIQUE,
        password_hash TEXT,
        phone TEXT UNIQUE,
        google_id TEXT,
        created_at TEXT,
        username TEXT
      );
      CREATE TABLE IF NOT EXISTS otps (
        phone TEXT PRIMARY KEY,
        code TEXT,
        expires_at TEXT,
        attempts INTEGER
      );
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        refresh_token TEXT UNIQUE,
        created_at TEXT,
        expires_at TEXT,
        revoked INTEGER DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS email_otps (
        email TEXT PRIMARY KEY,
        code TEXT,
        expires_at TEXT,
        attempts INTEGER,
        created_at TEXT
      );
    ''');
    
    // Add username column if it doesn't exist (migration)
    try {
      db.execute('ALTER TABLE users ADD COLUMN username TEXT;');
      print('✅ Added username column to existing users table');
    } catch (e) {
      // Column already exists, which is fine
      if (!e.toString().contains('duplicate column name')) {
        print('⚠️ Username column migration issue: $e');
      }
    }
    
    // Verify tables were created
    final tables = db.select("SELECT name FROM sqlite_master WHERE type='table';");
    print('✅ Database tables: ${tables.map((t) => t['name']).join(', ')}');
    print('✅ users.db opened and tables ensured');
    
    // Log existing users on startup
    final existingUsers = db.select('SELECT COUNT(*) as count FROM users;');
    print('📊 Existing users in database: ${existingUsers.first['count']}');
    
    dbAvailable = true;
  } catch (e) {
    // If native sqlite3 DLL is missing (common on some Windows setups), fall back to in-memory users cache
    dbAvailable = false;
    print('⚠️ SQLite initialization failed, falling back to in-memory users cache: $e');
  }
}

// Helper to issue JWTs with refresh token
Map<String, String> _issueTokens(String userId, String? email, {String role = 'user'}) {
  final accessJwt = JWT(
    {
      'sub': userId,
      'email': email,
      'role': role,
      'iat': DateTime.now().millisecondsSinceEpoch,
      'type': 'access',
    },
  );
  final accessToken = accessJwt.sign(SecretKey(jwtSecret), expiresIn: const Duration(hours: 1));
  
  final refreshJwt = JWT(
    {
      'sub': userId,
      'role': role,
      'iat': DateTime.now().millisecondsSinceEpoch,
      'type': 'refresh',
    },
  );
  final refreshToken = refreshJwt.sign(SecretKey(jwtSecret), expiresIn: const Duration(days: 30));
  
  // Store session in DB
  final sessionId = uuid.v4();
  final createdAt = DateTime.now().toIso8601String();
  final expiresAt = DateTime.now().add(const Duration(days: 30)).toIso8601String();
  _dbSaveSession(sessionId, userId, refreshToken, createdAt, expiresAt);
  
  return {'accessToken': accessToken, 'refreshToken': refreshToken};
}

// Helper to verify JWT and return user ID or null if invalid/expired
String? _verifyJWT(String token) {
  try {
    final jwt = JWT.verify(token, SecretKey(jwtSecret));
    final userId = jwt.payload['sub'] as String?;
    return userId;
  } catch (e) {
    print('❌ JWT verification failed: $e');
    return null;
  }
}

// Helper to check if a token is from an admin user
bool _isAdminToken(String token) {
  try {
    print('🔐 [ADMIN_CHECK] Verifying admin token, JWT secret length: ${jwtSecret.length}');
    final jwt = JWT.verify(token, SecretKey(jwtSecret));
    final role = jwt.payload['role'] as String?;
    final email = jwt.payload['email'] as String?;
    print('🔐 [ADMIN_CHECK] Token payload - role: $role, email: $email');
    final isAdmin = role == 'admin';
    print('🔐 [ADMIN_CHECK] Is admin: $isAdmin (role was "$role")');
    return isAdmin;
  } catch (e) {
    print('❌ [ADMIN_CHECK] Admin check failed: $e');
    return false;
  }
}

// Helper to check if two user IDs belong to the same person (by email)
// This handles cases where a user's account was migrated and got a new UUID
bool _isSameUser(String userId1, String userId2) {
  if (userId1 == userId2) return true; // Direct match
  
  // Get email for userId1
  String? email1;
  if (!dbAvailable) {
    try {
      email1 = usersCache.firstWhere((u) => u['id'] == userId1)['email'] as String?;
    } catch (_) {
      return false;
    }
  } else {
    try {
      final rows = db.select('SELECT email FROM users WHERE id = ?', [userId1]);
      if (rows.isNotEmpty) email1 = rows.first['email'] as String?;
    } catch (_) {
      return false;
    }
  }
  
  if (email1 == null) return false;
  
  // Get email for userId2
  String? email2;
  if (!dbAvailable) {
    try {
      email2 = usersCache.firstWhere((u) => u['id'] == userId2)['email'] as String?;
    } catch (_) {
      return false;
    }
  } else {
    try {
      final rows = db.select('SELECT email FROM users WHERE id = ?', [userId2]);
      if (rows.isNotEmpty) email2 = rows.first['email'] as String?;
    } catch (_) {
      return false;
    }
  }
  
  if (email2 == null) return false;
  
  // If both emails match, it's the same person
  return email1 == email2;
}

// Session DB helpers
void _dbSaveSession(String id, String userId, String refreshToken, String createdAt, String expiresAt) {
  if (!dbAvailable) {
    sessionsCache.add({'id': id, 'userId': userId, 'refreshToken': refreshToken, 'createdAt': createdAt, 'expiresAt': expiresAt, 'revoked': 0});
    return;
  }
  final stmt = db.prepare('INSERT INTO sessions (id, user_id, refresh_token, created_at, expires_at, revoked) VALUES (?, ?, ?, ?, ?, 0);');
  try {
    stmt.execute([id, userId, refreshToken, createdAt, expiresAt]);
  } finally {
    stmt.dispose();
  }
}

Map<String, dynamic>? _dbGetSessionByRefreshToken(String refreshToken) {
  if (!dbAvailable) {
    try {
      return sessionsCache.firstWhere((s) => s['refreshToken'] == refreshToken && (s['revoked'] as int) == 0);
    } catch (_) {
      return null;
    }
  }
  final rs = db.select('SELECT id, user_id, refresh_token, created_at, expires_at, revoked FROM sessions WHERE refresh_token = ? AND revoked = 0;', [refreshToken]);
  if (rs.isEmpty) return null;
  final r = rs.first;
  return {'id': r['id'], 'userId': r['user_id'], 'refreshToken': r['refresh_token'], 'createdAt': r['created_at'], 'expiresAt': r['expires_at'], 'revoked': r['revoked']};
}

void _dbRevokeSession(String refreshToken) {
  if (!dbAvailable) {
    final idx = sessionsCache.indexWhere((s) => s['refreshToken'] == refreshToken);
    if (idx != -1) sessionsCache[idx]['revoked'] = 1;
    return;
  }
  final stmt = db.prepare('UPDATE sessions SET revoked = 1 WHERE refresh_token = ?;');
  try {
    stmt.execute([refreshToken]);
  } finally {
    stmt.dispose();
  }
}

String? _asNullableString(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  return value.toString();
}

Map<String, dynamic> _normalizeMongoUser(Map<String, dynamic> mongoUser) {
  final resolvedId = _asNullableString(mongoUser['id']) ?? _asNullableString(mongoUser['_id']);
  return {
    'id': resolvedId,
    'email': _asNullableString(mongoUser['email']),
    'password_hash': _asNullableString(mongoUser['password_hash']),
    'phone': _asNullableString(mongoUser['phone']),
    'google_id': _asNullableString(mongoUser['google_id']),
    'created_at': _asNullableString(mongoUser['created_at']),
    'username': _asNullableString(mongoUser['username']),
    'admin_passkey': _asNullableString(mongoUser['admin_passkey']),
  };
}

// User helpers (DB-backed)
Future<Map<String, dynamic>?> _dbGetUserById(String id) async {
  // Try MongoDB first (production)
  if (mongoUsersCollection != null) {
    try {
      final mongoUser = await mongoUsersCollection!.findOne(where.eq('id', id));
      if (mongoUser != null) {
        return _normalizeMongoUser(mongoUser);
      }
    } catch (e) {
      print('[MongoDB] Error fetching user by id: $e');
    }
  }
  // Fall back to SQLite (local development)
  if (!dbAvailable) {
    try {
      return usersCache.firstWhere((u) => u['id'] == id);
    } catch (_) {
      return null;
    }
  }
  final ResultSet rs = db.select('SELECT * FROM users WHERE id = ?;', [id]);
  if (rs.isEmpty) return null;
  final row = rs.first;
  return {
    'id': row['id'] as String,
    'email': row['email'] as String?,
    'password_hash': row['password_hash'] as String?,
    'phone': row['phone'] as String?,
    'google_id': row['google_id'] as String?,
    'created_at': row['created_at'] as String?,
    'username': row['username'] as String?,
    'admin_passkey': row['admin_passkey'] as String?,
  };
}

// Ensure there is at least one default admin user in MongoDB
Future<void> _ensureDefaultAdminUser() async {
  try {
    if (mongoUsersCollection == null) {
      print('⚠️ [ADMIN_BOOTSTRAP] mongoUsersCollection is null, skipping admin seed');
      return;
    }

    final adminEmail = (
      Platform.environment['ADMIN_EMAIL'] ??
      _readLocalEnvTop('ADMIN_EMAIL', path: 'community_server/.env') ??
      _readLocalEnvTop('ADMIN_EMAIL') ??
      'admin@learnease.com'
    ).trim().toLowerCase();

    final adminPassword = (
      Platform.environment['ADMIN_PASSWORD'] ??
      _readLocalEnvTop('ADMIN_PASSWORD', path: 'community_server/.env') ??
      _readLocalEnvTop('ADMIN_PASSWORD') ??
      'Admin@123'
    ).trim();

    print('🔧 [ADMIN_BOOTSTRAP] Ensuring default admin user exists for email: $adminEmail');

    final existing = await mongoUsersCollection!.findOne(where.eq('email', adminEmail));

    final passwordHash = BCrypt.hashpw(adminPassword, BCrypt.gensalt());

    if (existing != null) {
      // Update password hash if needed, keep other fields intact
      await mongoUsersCollection!.updateOne(
        where.eq('email', adminEmail),
        modify.set('password_hash', passwordHash),
      );
      print('✅ [ADMIN_BOOTSTRAP] Admin user already exists, password updated');
      return;
    }

    final newId = uuid.v4();
    final createdAt = DateTime.now().toIso8601String();

    await mongoUsersCollection!.insertOne({
      'id': newId,
      'email': adminEmail,
      'password_hash': passwordHash,
      'username': 'admin',
      'role': 'admin',
      'created_at': createdAt,
    });

    print('✅ [ADMIN_BOOTSTRAP] Default admin user created in MongoDB');
  } catch (e, st) {
    print('❌ [ADMIN_BOOTSTRAP] Failed to ensure admin user: $e');
    print('❌ [ADMIN_BOOTSTRAP] StackTrace: $st');
  }
}
Future<Map<String, dynamic>?> _dbGetUserByEmail(String email) async {
  // Try MongoDB first (production)
  if (mongoUsersCollection != null) {
    try {
      final mongoUser = await mongoUsersCollection!.findOne(where.eq('email', email));
      if (mongoUser != null) {
        return _normalizeMongoUser(mongoUser);
      }
    } catch (e) {
      print('[MongoDB] Error fetching user by email: $e');
    }
  }
  
  // Fall back to SQLite (local development)
  if (!dbAvailable) {
    try {
      return usersCache.firstWhere((u) => u['email'] == email);
    } catch (_) {
      return null;
    }
  }
  final ResultSet rs = db.select('SELECT * FROM users WHERE email = ?;', [email]);
  if (rs.isEmpty) return null;
  final row = rs.first;
  return {
    'id': row['id'] as String,
    'email': row['email'] as String?,
    'password_hash': row['password_hash'] as String?,
    'phone': row['phone'] as String?,
    'google_id': row['google_id'] as String?,
    'created_at': row['created_at'] as String?,
    'username': row['username'] as String?,
    'admin_passkey': row['admin_passkey'] as String?,
  };
}

Map<String, dynamic>? _dbGetUserByPhone(String phone) {
  if (!dbAvailable) {
    try {
      return usersCache.firstWhere((u) => u['phone'] == phone);
    } catch (_) {
      return null;
    }
  }
  final ResultSet rs = db.select('SELECT * FROM users WHERE phone = ?;', [phone]);
  if (rs.isEmpty) return null;
  final row = rs.first;
  return {
    'id': row['id'] as String,
    'email': row['email'] as String?,
    'password_hash': row['password_hash'] as String?,
    'phone': row['phone'] as String?,
    'google_id': row['google_id'] as String?,
    'created_at': row['created_at'] as String?,
    'username': row['username'] as String?,
  };
}


Future<void> _dbInsertUser({required String id, String? email, String? password_hash, String? phone, String? google_id, required String created_at, String? username}) async {
  // PRIMARY: Insert to MongoDB (production database)
  try {
    if (mongoUsersCollection != null) {
      await mongoUsersCollection!.insertOne({
        'id': id,
        'email': email,
        'password_hash': password_hash,
        'phone': phone,
        'google_id': google_id,
        'created_at': created_at,
        'username': username,
      });
      print('✅ [DB_INSERT] User $id inserted to MongoDB');
    }
  } catch (e) {
    print('⚠️ [DB_INSERT] MongoDB insert failed: $e');
  }
  
  // FALLBACK: Insert to SQLite (local cache)
  if (!dbAvailable) {
    usersCache.add({'id': id, 'email': email, 'password_hash': password_hash, 'phone': phone, 'google_id': google_id, 'created_at': created_at, 'username': username});
    return;
  }
  final stmt = db.prepare('INSERT INTO users (id, email, password_hash, phone, google_id, created_at, username) VALUES (?, ?, ?, ?, ?, ?, ?);');
  try {
    stmt.execute([id, email, password_hash, phone, google_id, created_at, username]);
    print('✅ [DB_INSERT] User $id inserted to SQLite (fallback)');
  } catch (e) {
    print('⚠️ [DB_INSERT] SQLite insert failed: $e');
  } finally {
    stmt.dispose();
  }
}

void _dbUpdateGoogleId(String id, String googleId) {
  if (!dbAvailable) {
    final idx = usersCache.indexWhere((u) => u['id'] == id);
    if (idx != -1) usersCache[idx]['googleId'] = googleId;
    return;
  }
  final stmt = db.prepare('UPDATE users SET google_id = ? WHERE id = ?;');
  try {
    stmt.execute([googleId, id]);
  } finally {
    stmt.dispose();
  }
}
// OTP store: phone -> {code, expiresAt, attemptCount}
final Map<String, Map<String, dynamic>> otps = {};
// Email OTP store: email -> {code, expiresAt, attemptCount}
final Map<String, Map<String, dynamic>> emailOtps = {};

// OTP DB helpers
void _dbSaveOtp(String phone, String code, String expiresAt, int attempts) {
  if (!dbAvailable) {
    otps[phone] = {'code': code, 'expiresAt': expiresAt, 'attempts': attempts};
    return;
  }
  final stmt = db.prepare('INSERT OR REPLACE INTO otps (phone, code, expires_at, attempts) VALUES (?, ?, ?, ?);');
  try {
    stmt.execute([phone, code, expiresAt, attempts]);
  } finally {
    stmt.dispose();
  }
}

Map<String, dynamic>? _dbGetOtp(String phone) {
  if (!dbAvailable) return otps[phone];
  final rs = db.select('SELECT phone, code, expires_at, attempts FROM otps WHERE phone = ?;', [phone]);
  if (rs.isEmpty) return null;
  final r = rs.first;
  return {'phone': r['phone'], 'code': r['code'], 'expiresAt': r['expires_at'], 'attempts': r['attempts']};
}

void _dbDeleteOtp(String phone) {
  if (!dbAvailable) {
    otps.remove(phone);
    return;
  }
  final stmt = db.prepare('DELETE FROM otps WHERE phone = ?;');
  try {
    stmt.execute([phone]);
  } finally {
    stmt.dispose();
  }
}

// Email OTP helpers
void _dbSaveEmailOtp(String email, String code, String expiresAt, int attempts) {
  if (!dbAvailable) {
    emailOtps[email] = {'code': code, 'expiresAt': expiresAt, 'attempts': attempts};
    return;
  }
  final stmt = db.prepare('INSERT OR REPLACE INTO email_otps (email, code, expires_at, attempts, created_at) VALUES (?, ?, ?, ?, ?);');
  try {
    stmt.execute([email, code, expiresAt, attempts, DateTime.now().toIso8601String()]);
    print('💾 Email OTP saved to database: $email');
  } finally {
    stmt.dispose();
  }
}

Map<String, dynamic>? _dbGetEmailOtp(String email) {
  if (!dbAvailable) return emailOtps[email];
  final rs = db.select('SELECT email, code, expires_at, attempts FROM email_otps WHERE email = ?;', [email]);
  if (rs.isEmpty) return null;
  final r = rs.first;
  return {'email': r['email'], 'code': r['code'], 'expiresAt': r['expires_at'], 'attempts': r['attempts']};
}

void _dbDeleteEmailOtp(String email) {
  if (!dbAvailable) {
    emailOtps.remove(email);
    return;
  }
  final stmt = db.prepare('DELETE FROM email_otps WHERE email = ?;');
  try {
    stmt.execute([email]);
    print('🗑️ Email OTP deleted from database: $email');
  } finally {
    stmt.dispose();
  }
}

String _normalizeSecret(String value, {bool removeAllWhitespace = false}) {
  var normalized = value.trim();
  if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
      (normalized.startsWith("'") && normalized.endsWith("'"))) {
    normalized = normalized.substring(1, normalized.length - 1).trim();
  }
  if (removeAllWhitespace) {
    normalized = normalized.replaceAll(RegExp(r'\s+'), '');
  }
  return normalized;
}

String _sanitizeGmailAppPassword(String value) {
  // Gmail app passwords are 16 alphanumeric chars. Users often paste with
  // spaces or hidden punctuation from password managers.
  return value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
}

// Send email via SMTP
Future<bool> _sendEmail(String to, String subject, String body) async {
  print('[EMAIL] Attempting to send email to: $to');
  try {
    // Prefer workspace .env values first so local runs are deterministic.
    var smtpUser = _readLocalEnvTop('SMTP_USER', path: 'community_server/.env');
    smtpUser ??= _readLocalEnvTop('SMTP_USER', path: '.env');
    smtpUser ??= Platform.environment['SMTP_USER'];

    var smtpPassword = _readLocalEnvTop('SMTP_PASSWORD', path: 'community_server/.env');
    smtpPassword ??= _readLocalEnvTop('SMTP_PASSWORD', path: '.env');
    smtpPassword ??= _readLocalEnvTop('GMAIL_APP_PASSWORD', path: 'community_server/.env');
    smtpPassword ??= _readLocalEnvTop('GMAIL_APP_PASSWORD', path: '.env');
    smtpPassword ??= Platform.environment['SMTP_PASSWORD'];
    smtpPassword ??= Platform.environment['GMAIL_APP_PASSWORD'];

    var smtpHost = _readLocalEnvTop('SMTP_HOST', path: 'community_server/.env') ?? _readLocalEnvTop('SMTP_HOST', path: '.env') ?? Platform.environment['SMTP_HOST'] ?? 'smtp.gmail.com';
    var smtpPort = int.tryParse(_readLocalEnvTop('SMTP_PORT', path: 'community_server/.env') ?? _readLocalEnvTop('SMTP_PORT', path: '.env') ?? Platform.environment['SMTP_PORT'] ?? '587') ?? 587;

    if (smtpUser == null || smtpPassword == null) {
      print('⚠️ SMTP not configured. Missing: SMTP_USER or SMTP_PASSWORD');
      return false;
    }

    smtpUser = _normalizeSecret(smtpUser);
    smtpPassword = _normalizeSecret(smtpPassword);

    print('[EMAIL] Raw SMTP_USER from config: $smtpUser');
    print('[EMAIL] Normalized SMTP_USER: ${smtpUser.trim()}');

    final isGmail = smtpHost.toLowerCase().contains('gmail.com');
    if (isGmail) {
      // Gmail app passwords are commonly copied with spaces or hidden symbols.
      smtpPassword = _sanitizeGmailAppPassword(
        _normalizeSecret(smtpPassword, removeAllWhitespace: true),
      );
      print('[EMAIL] Gmail detected. Sanitized password length: ${smtpPassword.length} chars');
      final pwLen = smtpPassword.length;
      if (pwLen >= 8) {
        print('[EMAIL] Sanitized password (first 4 + last 4): ${smtpPassword.substring(0, 4)}***${smtpPassword.substring(pwLen - 4)}');
      }
      if (smtpPassword.length != 16) {
        print('[EMAIL] Warning: Gmail app password length is ${smtpPassword.length}, expected 16.');
      }
    }

    final useSsl = smtpPort == 465;

    final smtpServer = SmtpServer(
      smtpHost,
      port: smtpPort,
      username: smtpUser,
      password: smtpPassword,
      ssl: useSsl,
      allowInsecure: false,
    );

    final message = Message()
      ..from = Address(smtpUser, 'LearnEase')
      ..recipients.add(to)
      ..subject = subject
      ..html = body;

    print('[EMAIL] Sending email via SMTP ($smtpHost:$smtpPort)...');
    final sendReport = await send(message, smtpServer);
    print('✅ Email sent successfully via SMTP to $to');
    return true;
  } catch (e, stackTrace) {
    print('❌ Failed to send email via SMTP: $e');
    if (e.toString().contains('535')) {
      print('[EMAIL] Gmail authentication failed. Use a Google App Password (16 chars) with 2-Step Verification enabled.');
      print('[EMAIL] Do not use your regular Gmail account password for SMTP.');
    }
    print('Stack trace: $stackTrace');
    return false;
  }
}
// Simple JWT secret (override via .env in production)
// duplicate declarations removed

void main(List<String> args) async {
     final router = Router();

    // Admin registration endpoint
    router.post('/api/admin/register', (Request request) async {
      try {
        final body = await request.readAsString();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final email = (data['email'] as String?)?.trim().toLowerCase();
        final password = data['password'] as String?;
        final username = (data['username'] as String?)?.trim();
        if (email == null || password == null || email.isEmpty || password.length < 6) {
          return Response(400, body: jsonEncode({'error': 'Invalid email or password (min 6 chars)'}), headers: {'Content-Type': 'application/json'});
        }
        final hash = BCrypt.hashpw(password, BCrypt.gensalt());
        final newId = uuid.v4();
        final createdAt = DateTime.now().toIso8601String();
        // Insert admin into MongoDB
        if (mongoDb != null) {
          final adminCollection = mongoDb!.collection('admin');
          await adminCollection.insertOne({
            'id': newId,
            'email': email,
            'password_hash': hash,
            'username': username ?? email.split('@')[0],
            'role': 'admin',
            'created_at': createdAt,
          });
          print('✅ [DB_INSERT] Admin $newId inserted to MongoDB');
          return Response.ok(jsonEncode({'success': true, 'id': newId}), headers: {'Content-Type': 'application/json'});
        } else {
          return Response.internalServerError(body: jsonEncode({'error': 'MongoDB not connected'}), headers: {'Content-Type': 'application/json'});
        }
      } catch (e) {
        return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
      }
    });
    // Admin registration endpoint (correct placement)
    router.post('/api/admin/register', (Request request) async {
      try {
        final body = await request.readAsString();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final email = (data['email'] as String?)?.trim().toLowerCase();
        final password = data['password'] as String?;
        final username = (data['username'] as String?)?.trim();
        if (email == null || password == null || email.isEmpty || password.length < 6) {
          return Response(400, body: jsonEncode({'error': 'Invalid email or password (min 6 chars)'}), headers: {'Content-Type': 'application/json'});
        }
        final hash = BCrypt.hashpw(password, BCrypt.gensalt());
        final newId = uuid.v4();
        final createdAt = DateTime.now().toIso8601String();
        // Insert admin into MongoDB
        if (mongoDb != null) {
          final adminCollection = mongoDb!.collection('admin');
          await adminCollection.insertOne({
            'id': newId,
            'email': email,
            'password_hash': hash,
            'username': username ?? email.split('@')[0],
            'role': 'admin',
            'created_at': createdAt,
          });
          print('✅ [DB_INSERT] Admin $newId inserted to MongoDB');
          return Response.ok(jsonEncode({'success': true, 'id': newId}), headers: {'Content-Type': 'application/json'});
        } else {
          return Response.internalServerError(body: jsonEncode({'error': 'MongoDB not connected'}), headers: {'Content-Type': 'application/json'});
        }
      } catch (e) {
        return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
      }
    });
  
  // Handle OPTIONS requests for CORS preflight
  router.options('/<path|.*>', (Request request) {
    return Response.ok('', headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, PATCH',
      'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization, X-Requested-With',
      'Access-Control-Max-Age': '86400',
    });
  });
  
  // Connect to MongoDB
  try {
    // Try to read from environment first, then from .env files (in order of priority)
    var mongoUri = Platform.environment['MONGODB_URI'];
    
    mongoUri ??= _readLocalEnvTop('MONGODB_URI', path: 'community_server/.env');
    
    mongoUri ??= _readLocalEnvTop('MONGODB_URI', path: '.env');
    
    if (mongoUri == null) {
      throw Exception('MONGODB_URI not found in environment or .env files');
    }
    
    print('🔌 Attempting to connect to MongoDB...');
    print('📝 [DEBUG] Raw MongoDB URI: ' + mongoUri);
    print('📝 Connection URI: ${mongoUri.replaceAll(RegExp(r':[^@]+@'), ':***@')}'); // Log URI with password masked
    mongoDb = Db(mongoUri);
    await mongoDb!.open().timeout(const Duration(seconds: 10));
    contribCollection = mongoDb?.collection('contributions');
    quizResultsCollection = mongoDb?.collection('quiz_results');
    challengeResultsCollection = mongoDb?.collection('challenge_results');
    
    // User management collections (persistent across deployments)
    mongoUsersCollection = mongoDb?.collection('users');
    mongoSessionsCollection = mongoDb?.collection('sessions');
    mongoEmailOtpsCollection = mongoDb?.collection('email_otps');
    
    print('✅ MongoDB connected successfully');
    print('✅ Collections initialized: contributions, quiz_results, challenge_results, users, sessions, email_otps');

    // Ensure a default admin user exists so /api/auth/admin-login works out of the box
    await _ensureDefaultAdminUser();
    
    // Log user count from MongoDB
    if (mongoUsersCollection != null) {
      final userCount = await mongoUsersCollection!.count();
      print('📊 MongoDB users: $userCount');
    }
  } catch (e) {
    print('⚠️ MongoDB connection failed: $e');
    print('⚠️ Contributions feature will be unavailable. Attempting to use local cache...');
    // Set mongoDb and contribCollection to null to indicate offline mode
    mongoDb = null;
    contribCollection = null;
  }

  // Real-time contributions stream (Server-Sent Events) - only approved
  router.get('/api/contributions/stream', (Request request) async {
    final category = request.url.queryParameters['category'] ?? 'java';
    final controller = StreamController<String>();
    Timer? timer;
    timer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (contribCollection != null) {
        final filtered = await contribCollection?.find({'category': category, 'status': 'approved'}).toList() ?? [];
        controller.add('data: ${jsonEncode(filtered)}\n\n');
      } else {
        controller.add('data: []\n\n');
      }
    });
    controller.onCancel = () {
      timer?.cancel();
    };
    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    );
  });
  // Root endpoint - API documentation
  router.get('/', (Request request) {
    final html = '''
<!DOCTYPE html>
<html>
<head>
  <title>LearnEase Community API</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; background: #f5f5f5; }
    .container { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
    h1 { color: #2c3e50; }
    .endpoint { background: #ecf0f1; padding: 15px; margin: 10px 0; border-radius: 5px; }
    .method { display: inline-block; padding: 5px 10px; border-radius: 3px; font-weight: bold; color: white; }
    .get { background: #3498db; }
    .post { background: #2ecc71; }
    .put { background: #f39c12; }
    .delete { background: #e74c3c; }
    code { background: #34495e; color: #ecf0f1; padding: 2px 6px; border-radius: 3px; }
    .status { color: #27ae60; font-weight: bold; }
    a { color: #3498db; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <div class="container">
    <h1>🚀 LearnEase Community API</h1>
    <p class="status">✅ Server is running!</p>
  <!-- <p><strong>Total Contributions:</strong> ...</p> -->
    
    <h2>📚 Available Endpoints</h2>
    
    <div class="endpoint">
      <span class="method get">GET</span>
      <strong>/health</strong>
      <p>Check if the server is running</p>
      <a href="/health" target="_blank">Try it →</a>
    </div>
    
    <div class="endpoint">
      <span class="method get">GET</span>
      <strong>/api/contributions</strong>
      <p>Get all contributions</p>
      <a href="/api/contributions" target="_blank">Try it →</a>
    </div>
    
    <div class="endpoint">
      <span class="method get">GET</span>
      <strong>/api/contributions/{category}</strong>
      <p>Get contributions by category (java or dbms)</p>
      <a href="/api/contributions/java" target="_blank">Try Java →</a> | 
      <a href="/api/contributions/dbms" target="_blank">Try DBMS →</a>
    </div>
    
    <div class="endpoint">
      <span class="method post">POST</span>
      <strong>/api/contributions</strong>
      <p>Add a new contribution</p>
      <code>Content-Type: application/json</code>
    </div>
    
    <div class="endpoint">
      <span class="method put">PUT</span>
      <strong>/api/contributions/{id}</strong>
      <p>Update a contribution</p>
      <code>Content-Type: application/json</code>
    </div>
    
    <div class="endpoint">
      <span class="method delete">DELETE</span>
      <strong>/api/contributions/{id}</strong>
      <p>Delete a contribution</p>
    </div>
    
    <h2>📖 Quick Test</h2>
    <p>Try fetching contributions:</p>
    <pre style="background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 5px; overflow-x: auto;">curl ${request.requestedUri.scheme}://${request.requestedUri.host}/api/contributions</pre>
    
    <hr style="margin: 30px 0; border: none; border-top: 1px solid #ecf0f1;">
    <p style="text-align: center; color: #7f8c8d;">
      <small>LearnEase Community Server | 
      <a href="https://github.com/yourusername/learnease" target="_blank">Documentation</a>
      </small>
    </p>
  </div>
</body>
</html>
    ''';
    return Response.ok(
      html,
      headers: {'Content-Type': 'text/html'},
    );
  });

  // Health check
  router.get('/health', (Request request) {
    return Response.ok('Community Server is running!');
  });

  // Debug endpoint to check SMTP configuration (remove in production)
  router.get('/api/debug/email-config', (Request request) {
    final smtpUser = Platform.environment['SMTP_USER'] ?? 
                     _readLocalEnvTop('SMTP_USER', path: 'community_server/.env') ?? 
                     _readLocalEnvTop('SMTP_USER', path: '.env');
    final smtpPass = Platform.environment['SMTP_PASSWORD'] ?? 
                     _readLocalEnvTop('SMTP_PASSWORD', path: 'community_server/.env') ?? 
                     _readLocalEnvTop('SMTP_PASSWORD', path: '.env');
    
    return Response.ok(jsonEncode({
      'smtp_user': smtpUser ?? 'NOT_SET',
      'smtp_password_set': smtpPass != null,
      'smtp_password_length': smtpPass?.length ?? 0,
      'smtp_password_last_4': smtpPass != null && smtpPass.length >= 4 
          ? smtpPass.substring(smtpPass.length - 4) 
          : 'N/A',
    }), headers: {'Content-Type': 'application/json'});
  });

  // --- AUTH ROUTES ---
  // Register (email/password)
  router.post('/api/auth/register', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      final password = data['password'] as String?;
      final phone = (data['phone'] as String?)?.trim();
      final username = (data['username'] as String?)?.trim();
      
      if (email == null || password == null || email.isEmpty || password.length < 6) {
        return Response(400, body: jsonEncode({'error': 'Invalid email or password (min 6 chars)'}), headers: {'Content-Type': 'application/json'});
      }

      final existing = await _dbGetUserByEmail(email);
      if (existing != null) {
        return Response(409, body: jsonEncode({'error': 'Email already registered'}), headers: {'Content-Type': 'application/json'});
      }

      final hash = BCrypt.hashpw(password, BCrypt.gensalt());
      final newId = uuid.v4();
      final createdAt = DateTime.now().toIso8601String();
      final defaultUsername = username ?? email.split('@')[0];
      await _dbInsertUser(id: newId, email: email, password_hash: hash, phone: phone, google_id: null, created_at: createdAt, username: defaultUsername);
      // Generate and send OTP after registration
      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
      final expires = DateTime.now().add(const Duration(minutes: 5));
      _dbSaveEmailOtp(email, code, expires.toIso8601String(), 0);
      final subject = 'LearnEase Registration OTP';
      final bodyText = 'Your LearnEase registration OTP is: $code\nValid for 5 minutes.';
      final sent = await _sendEmail(email, subject, bodyText);
      final tokens = _issueTokens(newId, email);
      return Response.ok(jsonEncode({
        'token': tokens['accessToken'],
        'refreshToken': tokens['refreshToken'],
        'user': {'id': newId, 'email': email, 'phone': phone, 'username': defaultUsername},
        'otpSent': sent,
        'otpMessage': sent ? 'OTP sent to email' : 'OTP send failed, check server logs',
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Login (email/password)
  router.post('/api/auth/login', (Request request) async {
    try {
      final body = await request.readAsString();
      print('🔐 [LOGIN] Raw body: $body');
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      final password = data['password'] as String?;
      print('🔐 [LOGIN] Parsed email: $email, password length: ${password?.length}');
      print('🔐 [LOGIN] Attempt for email: $email');
      if (email == null || password == null) {
        print('❌ [LOGIN] Missing credentials');
        return Response(400, body: jsonEncode({'error': 'Missing credentials'}), headers: {'Content-Type': 'application/json'});
      }

      final user = await _dbGetUserByEmail(email);
      if (user == null) {
        print('❌ [LOGIN] User not found for email: $email');
        return Response(401, body: jsonEncode({'error': 'Invalid credentials'}), headers: {'Content-Type': 'application/json'});
      }
      print('✅ [LOGIN] User found: ${user['email']}');
      print('🔐 [LOGIN] User data: id=${user['id']}, email=${user['email']}, hasHash=${user['password_hash'] != null}');
      
      final hash = user['password_hash'] as String?;
      if (hash == null) {
        print('❌ [LOGIN] No password hash found for user');
        return Response(401, body: jsonEncode({'error': 'Invalid credentials'}), headers: {'Content-Type': 'application/json'});
      }
      
      print('🔐 [LOGIN] Checking password with hash: ${hash.substring(0, 20)}...');
      final ok = BCrypt.checkpw(password, hash);
      print('🔐 [LOGIN] BCrypt result: $ok');
      if (!ok) {
        print('❌ [LOGIN] Password check failed for $email');
        return Response(401, body: jsonEncode({'error': 'Invalid credentials'}), headers: {'Content-Type': 'application/json'});
      }
      print('✅ [LOGIN] Password verified for $email');
      
      // Check if user is an admin (has admin passkey)
      final isAdmin = (user['admin_passkey'] as String?) != null;
      final role = isAdmin ? 'admin' : 'user';
      print('🔑 [LOGIN] User role determined: $role (isAdmin=$isAdmin)');
      
      final userId = user['id']?.toString();
      if (userId == null || userId.isEmpty) {
        print('❌ [LOGIN] User id missing for $email');
        return Response.internalServerError(
          body: jsonEncode({'error': 'User record is missing id'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      final tokens = _issueTokens(userId, email, role: role);
      print('✅ [LOGIN] Tokens issued for $email with role: $role');
      return Response.ok(jsonEncode({'token': tokens['accessToken'], 'refreshToken': tokens['refreshToken'], 'user': {'id': user['id'], 'email': user['email'], 'phone': user['phone'], 'role': role}}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ [LOGIN] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Admin login with passkey verification
  router.post('/api/auth/admin-login', (Request request) async {
    try {
      final body = await request.readAsString();
      print('👨‍💼 [ADMIN_LOGIN] Raw body: $body');
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      final password = data['password'] as String?;
      
      print('👨‍💼 [ADMIN_LOGIN] Attempt for email: $email');
      
      if (email == null || password == null) {
        print('❌ [ADMIN_LOGIN] Missing credentials');
        return Response(400, body: jsonEncode({'error': 'Missing credentials'}), headers: {'Content-Type': 'application/json'});
      }

      // ✅ Try MongoDB first, then fall back to SQLite
      Map<String, dynamic>? user;
      
      // Try MongoDB
      if (mongoUsersCollection != null) {
        try {
          final mongoUser = await mongoUsersCollection!.findOne(where.eq('email', email));
          if (mongoUser != null) {
            user = {
              'id': mongoUser['id'],
              'email': mongoUser['email'],
              'password_hash': mongoUser['password_hash'],
              'username': mongoUser['username'],
              'role': mongoUser['role']
            };
            print('👨‍💼 [ADMIN_LOGIN] Found admin in MongoDB: $email (role: ${user['role']})');
          }
        } catch (e) {
          print('⚠️ [ADMIN_LOGIN] MongoDB lookup failed, trying SQLite: $e');
        }
      }
      
      // Fallback to SQLite if not found in MongoDB
      user ??= await _dbGetUserByEmail(email);
      
      if (user == null) {
        print('❌ [ADMIN_LOGIN] User not found for email: $email');
        return Response(401, body: jsonEncode({'error': 'Invalid credentials'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Verify password (use snake_case for MongoDB)
      final hash = user['password_hash'] as String?;
      print('[ADMIN_LOGIN] Debug: password entered = "$password"');
      print('[ADMIN_LOGIN] Debug: hash from DB = "$hash"');
      final passwordOk = hash != null && BCrypt.checkpw(password, hash);
      print('[ADMIN_LOGIN] Debug: BCrypt.checkpw result = $passwordOk');
      if (hash == null || !passwordOk) {
        print('❌ [ADMIN_LOGIN] Password check failed for $email (hash present: ${hash != null})');
        return Response(401, body: jsonEncode({'error': 'Invalid credentials'}), headers: {'Content-Type': 'application/json'});
      }
      
      print('✅ [ADMIN_LOGIN] Password verified for $email');
      
      // Passkey verification removed
      
      // Issue tokens with admin role
      var userId = user['id']?.toString();
      
      // ✅ FIX: If user doesn't have an id, generate one and update the record
      if (userId == null || userId.isEmpty) {
        print('⚠️ [ADMIN_LOGIN] User id missing for $email, generating new one');
        userId = uuid.v4();
        
        // Update user record with the new id
        try {
          if (dbAvailable) {
            db.execute('UPDATE users SET id = ? WHERE email = ?', [userId, email]);
            print('✅ [ADMIN_LOGIN] Generated and stored new id: $userId for $email');
          }
        } catch (e) {
          print('⚠️ [ADMIN_LOGIN] Failed to update user id: $e');
        }
        
        user['id'] = userId;
      }
      
      final tokens = _issueTokens(userId, email, role: 'admin');
      print('✅ [ADMIN_LOGIN] Admin tokens issued for $email with role=admin');
      
      return Response.ok(jsonEncode({
        'token': tokens['accessToken'],
        'refreshToken': tokens['refreshToken'],
        'user': {
          'id': user['id'],
          'email': user['email'],
          'username': user['username'],
          'role': 'admin'
        }
      }), headers: {'Content-Type': 'application/json'});
    } catch (e, st) {
      print('❌ [ADMIN_LOGIN] Exception: $e');
      print('❌ [ADMIN_LOGIN] StackTrace: $st');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Admin password reset (verify passkey, hash new password, update DB)
  router.post('/api/auth/admin-reset-password', (Request request) async {
    try {
      final body = await request.readAsString();
      print('🔐 [ADMIN_RESET] Raw body: $body');
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      // Passkey removed
      final newPassword = data['newPassword'] as String?;
      
      print('🔐 [ADMIN_RESET] Attempt for email: $email');
      
      if (email == null || newPassword == null) {
        print('❌ [ADMIN_RESET] Missing parameters');
        return Response(400, body: jsonEncode({'error': 'Missing parameters'}), headers: {'Content-Type': 'application/json'});
      }

      if (newPassword.length < 6) {
        print('❌ [ADMIN_RESET] New password too short');
        return Response(400, body: jsonEncode({'error': 'Password must be at least 6 characters'}), headers: {'Content-Type': 'application/json'});
      }

      // Verify user exists
      final user = await _dbGetUserByEmail(email);
      if (user == null) {
        print('❌ [ADMIN_RESET] User not found for email: $email');
        return Response(401, body: jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Passkey verification removed
      
      // Hash the new password with BCrypt
      final newPasswordHash = BCrypt.hashpw(newPassword, BCrypt.gensalt());
      print('🔐 [ADMIN_RESET] New password hashed');
      
      // Update password in MongoDB
      if (mongoUsersCollection != null) {
        await mongoUsersCollection!.updateOne(
          where.eq('email', email),
          modify.set('password_hash', newPasswordHash)
        );
        print('✅ [ADMIN_RESET] Password updated in MongoDB for $email');
      } else {
        print('❌ [ADMIN_RESET] MongoDB not available');
        return Response.internalServerError(body: jsonEncode({'error': 'Database not available'}), headers: {'Content-Type': 'application/json'});
      }
      
      return Response.ok(jsonEncode({
        'success': true,
        'message': 'Password reset successfully',
        'email': email
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ [ADMIN_RESET] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // TEMPORARY: Setup admin credentials (password + passkey)
  // DELETE THIS ENDPOINT after setup is complete!
  router.post('/api/admin/setup-passkey', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final password = data['password'] as String?;
      final passkey = data['passkey'] as String?;
      final secretKey = data['secret'] as String?;
      
      // Simple security: require a secret key
      if (secretKey != 'learnease-setup-2024') {
        return Response(403, body: jsonEncode({'error': 'Unauthorized'}), headers: {'Content-Type': 'application/json'});
      }
      
      if (password == null || password.length < 6) {
        return Response(400, body: jsonEncode({'error': 'Password must be at least 6 characters'}), headers: {'Content-Type': 'application/json'});
      }
      
      if (passkey == null || passkey.length < 6) {
        return Response(400, body: jsonEncode({'error': 'Passkey must be at least 6 characters'}), headers: {'Content-Type': 'application/json'});
      }
      
      print('🔐 [SETUP] Setting admin password and passkey...');
      
      if (mongoUsersCollection == null) {
        return Response.internalServerError(body: jsonEncode({'error': 'MongoDB not available'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Hash the password and passkey
      final hashedPassword = BCrypt.hashpw(password, BCrypt.gensalt());
      final hashedPasskey = BCrypt.hashpw(passkey, BCrypt.gensalt());
      
      print('🔐 [SETUP] Hashing complete, updating MongoDB...');
      
      // Update admin user with both password and passkey
      final result = await mongoUsersCollection!.updateOne(
        where.eq('email', 'admin@learnease.com'),
        modify.set('password_hash', hashedPassword).set('admin_passkey', hashedPasskey),
      );
      
      if (result.isSuccess) {
        print('✅ [SETUP] Admin credentials set successfully!');
        print('   Password: $password');
        print('   Passkey: $passkey');
        return Response.ok(jsonEncode({
          'success': true,
          'message': 'Admin credentials set successfully',
          'password': password,
          'passkey': passkey
        }), headers: {'Content-Type': 'application/json'});
      } else {
        return Response.internalServerError(body: jsonEncode({'error': 'Failed to update credentials'}), headers: {'Content-Type': 'application/json'});
      }
    } catch (e) {
      print('❌ [SETUP] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Send OTP to phone (placeholder - logs to console). In production plug Twilio or other SMS provider.
  router.post('/api/auth/send-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final phone = (data['phone'] as String?)?.trim();
      if (phone == null || phone.length < 6) return Response(400, body: jsonEncode({'error': 'Invalid phone'}), headers: {'Content-Type': 'application/json'});
      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
      final expires = DateTime.now().add(const Duration(minutes: 5));
      _dbSaveOtp(phone, code, expires.toIso8601String(), 0);
      print('✅ OTP saved for $phone: $code (expires ${expires.toIso8601String()})');
      
      var sentVia = 'console';
      
      // Try MSG91 first (Indian service - cheapest)
      final msg91Key = Platform.environment['MSG91_AUTH_KEY'] ?? _readLocalEnvTop('MSG91_AUTH_KEY');
      final msg91Route = Platform.environment['MSG91_ROUTE'] ?? _readLocalEnvTop('MSG91_ROUTE') ?? '4';
      
      if (msg91Key != null && msg91Key != 'YOUR_MSG91_AUTH_KEY_HERE') {
        try {
          final uri = Uri.parse('https://api.msg91.com/apiv5/flow/send').replace(queryParameters: {
            'authkey': msg91Key,
            'mobiles': phone,
            'message': 'Your LearnEase OTP is: $code. Valid for 5 minutes.',
            'route': msg91Route,
            'sender': 'LRNEASE',
          });
          final resp = await http.get(uri).timeout(const Duration(seconds: 10));
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            sentVia = 'msg91';
            print('📱 SMS sent via MSG91 to $phone');
          } else {
            print('❌ MSG91 send failed (${resp.statusCode}): ${resp.body}');
          }
        } catch (e) {
          print('❌ MSG91 exception: $e');
        }
      }
      
      // Fallback to Twilio if MSG91 not configured
      if (sentVia == 'console') {
        final twSid = Platform.environment['TWILIO_ACCOUNT_SID'] ?? _readLocalEnvTop('TWILIO_ACCOUNT_SID');
        final twToken = Platform.environment['TWILIO_AUTH_TOKEN'] ?? _readLocalEnvTop('TWILIO_AUTH_TOKEN');
        final twFrom = Platform.environment['TWILIO_FROM'] ?? _readLocalEnvTop('TWILIO_FROM');
        
        if (twSid != null && twToken != null && twFrom != null) {
          try {
            final uri = Uri.parse('https://api.twilio.com/2010-04-01/Accounts/$twSid/Messages.json');
            final bodyMap = {'From': twFrom, 'To': phone, 'Body': 'Your LearnEase OTP is: $code'};
            final resp = await http.post(uri, headers: {
              'Authorization': 'Basic ${base64Encode(utf8.encode('$twSid:$twToken'))}'
            }, body: bodyMap).timeout(const Duration(seconds: 10));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              sentVia = 'twilio';
              print('📱 SMS sent via Twilio to $phone');
            } else {
              print('❌ Twilio send failed (${resp.statusCode}): ${resp.body}');
            }
          } catch (e) {
            print('❌ Twilio exception: $e');
          }
        }
      }
      
      if (sentVia == 'console') print('📋 OTP for $phone: $code (check terminal)');
      return Response.ok(jsonEncode({'sent': true}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Send OTP to email (for LOGIN - requires existing user)
  router.post('/api/auth/send-email-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      print('[LOGIN OTP] Received send-email-otp request: ' + body);
      final data = jsonDecode(body) as Map<String, dynamic>;
      var email = (data['email'] as String?)?.trim().toLowerCase();
      final password = data['password'] as String?;
      
      print('[LOGIN OTP] Parsed email: "$email"');
      print('[LOGIN OTP] Password received: ${password != null ? "YES (length=${password.length})" : "NO"}');
      
      if (email == null || email.isEmpty) {
        print('[LOGIN OTP] ❌ Email is empty or null');
        return Response(400, body: jsonEncode({'error': 'Email is required'}), headers: {'Content-Type': 'application/json'});
      }
      
      if (!email.contains('@')) {
        print('[LOGIN OTP] ❌ Invalid email format: $email');
        return Response(400, body: jsonEncode({'error': 'Invalid email format'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Ensure email is lowercase and trimmed
      email = email.trim().toLowerCase();
      print('[LOGIN OTP] Final email (normalized): "$email"');
      
      // Check if user exists before sending OTP (security fix)
      print('[LOGIN OTP] 🔍 Looking up user with email: "$email"');
      final user = await _dbGetUserByEmail(email);
      if (user == null) {
        // Return error for non-existent email for login attempts
        print('[LOGIN OTP] ❌ Email not registered: $email');
        print('[LOGIN OTP] ❌ Checking all registered emails in database:');
        try {
          final allUsers = db.select('SELECT LOWER(email) as email FROM users;');
          for (final row in allUsers) {
            print('[LOGIN OTP]   • ${row['email']}');
          }
        } catch (e) {
          print('[LOGIN OTP]   Error listing users: $e');
        }
        return Response(401, body: jsonEncode({'error': 'Email not registered. Please sign up first.', 'sent': false}), headers: {'Content-Type': 'application/json'});
      }
      
      print('[LOGIN OTP] ✅ User found: email=${user['email']}, hasPassword=${user['password_hash'] != null && (user['password_hash'] as String).isNotEmpty}');
      print('[LOGIN OTP] 🔑 Password to verify: "$password" (length=${password?.length ?? 0})');
      
      // Validate password if provided (for login flow)
      if (password != null && password.isNotEmpty) {
        print('[LOGIN OTP] Validating password (length=${password.length})...');
        final storedHash = user['password_hash'] as String?;
        
        if (storedHash == null || storedHash.isEmpty) {
          print('[LOGIN OTP] ❌ No password hash found for user - account may have been created via OAuth');
          return Response(401, body: jsonEncode({'error': 'This account does not have a password set. Please use social login or reset your password.', 'sent': false}), headers: {'Content-Type': 'application/json'});
        }
        
        // Verify password
        print('[LOGIN OTP] Testing BCrypt...');
        print('[LOGIN OTP] 🔐 Stored Hash: ${storedHash.substring(0, 30)}...');
        print('[LOGIN OTP] 🔑 Plain Password: "$password"');
        bool pwdValid = false;
        try {
          pwdValid = BCrypt.checkpw(password, storedHash);
        } catch (bcryptErr) {
          print('[LOGIN OTP] ❌ BCrypt error: $bcryptErr');
          print('[LOGIN OTP] ❌ BCrypt Stack: ${bcryptErr.runtimeType}');
          return Response(401, body: jsonEncode({'error': 'Password verification failed. Please try again.', 'sent': false}), headers: {'Content-Type': 'application/json'});
        }
        
        print('[LOGIN OTP] BCrypt result: $pwdValid');
        if (!pwdValid) {
          print('[LOGIN OTP] ❌ Invalid password for: $email');
          return Response(401, body: jsonEncode({'error': 'Incorrect password. Please try again.', 'sent': false}), headers: {'Content-Type': 'application/json'});
        }
        print('[LOGIN OTP] ✅ Password verified for: $email');
      }
      
      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
      final expires = DateTime.now().add(const Duration(minutes: 5));
      _dbSaveEmailOtp(email, code, expires.toIso8601String(), 0);
      print('[LOGIN OTP] ✅ Email OTP saved for $email: $code (expires ${expires.toIso8601String()})');
      
      final subject = 'LearnEase Login OTP';
      final bodyText = 'Your LearnEase login OTP is: $code\nValid for 5 minutes.';

      final sent = await _sendEmail(email, subject, bodyText);
      print('[LOGIN OTP] Email send result: ${sent ? 'SUCCESS' : 'FAILURE'}');

      if (!sent) {
        // ✅ DEV MODE: Allow demo/testing by returning OTP if email fails
        final devMode = (Platform.environment['DEV_MODE'] ?? _readLocalEnvTop('DEV_MODE') ?? '').toLowerCase();
        if (devMode == '1' || devMode == 'true' || devMode == 'yes') {
          print('[LOGIN OTP] 🔧 DEV MODE ACTIVE - Returning OTP code in response');
          return Response.ok(
            jsonEncode({
              'sent': true,
              'message': 'OTP would be sent (DEV MODE - returned in response)',
              'devCode': code,  // For demo purposes only!
              'devNote': 'This is for development/demo only. In production, email must be sent.'
            }),
            headers: {'Content-Type': 'application/json'},
          );
        }
        
        _dbDeleteEmailOtp(email);
        return Response(
          503,
          body: jsonEncode({
            'sent': false,
            'error': 'Unable to send OTP email. Check SMTP configuration or enable DEV_MODE=true'
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      return Response.ok(
        jsonEncode({'sent': true, 'message': 'OTP sent to your email'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('[LOGIN OTP] ❌ Exception: $e');
      print('[LOGIN OTP] Stack: ${e.runtimeType}');
      return Response.internalServerError(body: jsonEncode({'error': 'Server error: ${e.toString()}'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Send OTP to email (for SIGNUP - creates new user)
  router.post('/api/auth/send-signup-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      print('[SIGNUP OTP] Received send-signup-otp request: ' + body);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      if (email == null || !email.contains('@')) return Response(400, body: jsonEncode({'error': 'Invalid email'}), headers: {'Content-Type': 'application/json'});
      
      // Check if user already exists
      final user = await _dbGetUserByEmail(email);
      if (user != null) {
        print('[SIGNUP OTP] ❌ Email already registered: $email');
        return Response(409, body: jsonEncode({'error': 'Email already registered', 'sent': false}), headers: {'Content-Type': 'application/json'});
      }
      
      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
      final expires = DateTime.now().add(const Duration(minutes: 5));
      _dbSaveEmailOtp(email, code, expires.toIso8601String(), 0);
      print('[SIGNUP OTP] Email OTP saved for $email: $code (expires ${expires.toIso8601String()})');
      
      final subject = 'LearnEase Signup OTP';
      final bodyText = 'Your LearnEase signup OTP is: $code\nValid for 5 minutes.';
      final sent = await _sendEmail(email, subject, bodyText);
      print('[SIGNUP OTP] Email send result: ${sent ? 'SUCCESS' : 'FAILURE'}');

      if (!sent) {
        // ✅ DEV MODE: Allow demo/testing by returning OTP if email fails
        final devMode = (Platform.environment['DEV_MODE'] ?? _readLocalEnvTop('DEV_MODE') ?? '').toLowerCase();
        if (devMode == '1' || devMode == 'true' || devMode == 'yes') {
          print('[SIGNUP OTP] 🔧 DEV MODE ACTIVE - Returning OTP code in response');
          return Response.ok(
            jsonEncode({
              'sent': true,
              'message': 'OTP would be sent (DEV MODE - returned in response)',
              'devCode': code,  // For demo purposes only!
              'devNote': 'This is for development/demo only. In production, email must be sent.'
            }),
            headers: {'Content-Type': 'application/json'},
          );
        }
        
        _dbDeleteEmailOtp(email);
        return Response(
          503,
          body: jsonEncode({
            'sent': false,
            'error': 'Unable to send OTP email. Check SMTP configuration or enable DEV_MODE=true'
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      return Response.ok(
        jsonEncode({'sent': true, 'message': 'OTP sent to your email'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('[SIGNUP OTP] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Verify password reset OTP and set new password
  router.post('/api/auth/verify-reset-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      // ✅ FIX: Handle code as integer or string from JSON
      var codeValue = data['code'];
      String? code;
      if (codeValue != null) {
        if (codeValue is String) {
          code = codeValue.trim();
        } else if (codeValue is int) {
          code = codeValue.toString();
        } else {
          code = codeValue.toString().trim();
        }
      }
      final newPassword = data['newPassword'] as String?;
      print('[RESET OTP] Verify attempt: email=$email, code=$code');
      if (email == null || code == null || newPassword == null || newPassword.length < 6) {
        return Response(400, body: jsonEncode({'error': 'Missing or invalid fields'}), headers: {'Content-Type': 'application/json'});
      }
      final record = _dbGetEmailOtp(email);
      print('[RESET OTP] 🔍 Looking up OTP for "$email"');
      print('[RESET OTP] OTP record found: ${record != null ? '✅ YES' : '❌ NO'}');
      if (record != null) {
        print('[RESET OTP] 📋 Stored Code: ${record['code']}, Provided: $code');
      } else {
        print('[RESET OTP] ❌ NO OTP FOUND for email: "$email"');
        print('[RESET OTP] 🗂️ Available emails in emailOtps: ${emailOtps.keys.toList()}');
      }
      if (record == null) return Response(400, body: jsonEncode({'error': 'No OTP requested'}), headers: {'Content-Type': 'application/json'});
      final expires = DateTime.parse(record['expiresAt'] as String);
      if (DateTime.now().isAfter(expires)) {
        return Response(400, body: jsonEncode({'error': 'OTP expired'}), headers: {'Content-Type': 'application/json'});
      }
      // ✅ FIX: Ensure stored code is also a string
      var storedCode = record['code'];
      if (storedCode is! String) {
        storedCode = storedCode.toString();
      }
      storedCode = storedCode.trim();
      if (storedCode != code) {
        final attempts = (record['attempts'] as int? ?? 0) + 1;
        _dbSaveEmailOtp(email, storedCode, record['expiresAt'] as String, attempts);
        return Response(401, body: jsonEncode({'error': 'Invalid code'}), headers: {'Content-Type': 'application/json'});
      }
      // OTP valid, update password
      final user = await _dbGetUserByEmail(email);
      if (user == null) return Response(404, body: jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      final hash = BCrypt.hashpw(newPassword, BCrypt.gensalt());
      final stmt = db.prepare('UPDATE users SET password_hash = ? WHERE id = ?;');
      try {
        stmt.execute([hash, user['id']]);
      } finally {
        stmt.dispose();
      }
      _dbDeleteEmailOtp(email);
      print('[RESET OTP] Password updated for $email');
      return Response.ok(jsonEncode({'success': true}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('[RESET OTP] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Validate reset OTP without changing password (used before user enters new password)
  router.post('/api/auth/validate-reset-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      // ✅ FIX: Handle code as integer or string from JSON
      var codeValue = data['code'];
      String? code;
      if (codeValue != null) {
        if (codeValue is String) {
          code = codeValue.trim();
        } else if (codeValue is int) {
          code = codeValue.toString();
        } else {
          code = codeValue.toString().trim();
        }
      }
      print('[VALIDATE RESET OTP] Checking: email=$email, code=$code');
      
      if (email == null || code == null) {
        return Response(400, body: jsonEncode({'error': 'Missing email or code'}), headers: {'Content-Type': 'application/json'});
      }
      
      final record = _dbGetEmailOtp(email);
      print('[VALIDATE RESET OTP] 🔍 Looking up OTP for "$email"');
      if (record == null) {
        return Response(400, body: jsonEncode({'error': 'No OTP requested for this email'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Check expiry
      final expires = DateTime.parse(record['expiresAt'] as String);
      if (DateTime.now().isAfter(expires)) {
        print('[VALIDATE RESET OTP] ⏰ OTP expired');
        return Response(400, body: jsonEncode({'error': 'OTP has expired'}), headers: {'Content-Type': 'application/json'});
      }
      
      // ✅ FIX: Ensure stored code is also a string
      var storedCode = record['code'];
      if (storedCode is! String) {
        storedCode = storedCode.toString();
      }
      storedCode = storedCode.trim();
      
      // Check code match
      if (storedCode != code) {
        print('[VALIDATE RESET OTP] ❌ Code mismatch. Expected: $storedCode, Got: $code');
        final attempts = (record['attempts'] as int? ?? 0) + 1;
        _dbSaveEmailOtp(email, storedCode, record['expiresAt'] as String, attempts);
        return Response(401, body: jsonEncode({'error': 'Invalid OTP code'}), headers: {'Content-Type': 'application/json'});
      }
      
      print('[VALIDATE RESET OTP] ✅ OTP is valid');
      return Response.ok(jsonEncode({'valid': true}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('[VALIDATE RESET OTP] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  router.post('/api/auth/verify-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final phone = (data['phone'] as String?)?.trim();
      // ✅ FIX: Handle code as integer or string from JSON
      var codeValue = data['code'];
      String? code;
      if (codeValue != null) {
        if (codeValue is String) {
          code = codeValue.trim();
        } else if (codeValue is int) {
          code = codeValue.toString();
        } else {
          code = codeValue.toString().trim();
        }
      }
      print('🔍 Verify OTP attempt: phone=$phone, code=$code');
      if (phone == null || code == null) return Response(400, body: jsonEncode({'error': 'Missing phone or code'}), headers: {'Content-Type': 'application/json'});
      final record = _dbGetOtp(phone);
      print('📋 OTP record found: ${record != null ? '✅ YES' : '❌ NO'}');
      if (record != null) print('   Stored OTP: ${record['code']}, Provided: $code');
      if (record == null) return Response(400, body: jsonEncode({'error': 'No OTP requested'}), headers: {'Content-Type': 'application/json'});
      final expires = DateTime.parse(record['expiresAt'] as String);
      if (DateTime.now().isAfter(expires)) {
        print('⏰ OTP expired');
        return Response(400, body: jsonEncode({'error': 'OTP expired'}), headers: {'Content-Type': 'application/json'});
      }
      // ✅ FIX: Ensure stored code is also a string
      var storedCode = record['code'];
      if (storedCode is! String) {
        storedCode = storedCode.toString();
      }
      storedCode = storedCode.trim();
      if (storedCode != code) {
        print('❌ OTP code mismatch');
        final attempts = (record['attempts'] as int? ?? 0) + 1;
        _dbSaveOtp(phone, storedCode, record['expiresAt'] as String, attempts);
        return Response(401, body: jsonEncode({'error': 'Invalid code'}), headers: {'Content-Type': 'application/json'});
      }
      print('✅ OTP verified successfully');
      // OTP valid - find or create user by phone
      var user = _dbGetUserByPhone(phone);
      if (user == null) {
        final newId = uuid.v4();
        final createdAt = DateTime.now().toIso8601String();
        await _dbInsertUser(id: newId, email: null, password_hash: null, phone: phone, google_id: null, created_at: createdAt);
        user = await _dbGetUserById(newId);
        print('👤 New user created: $newId');
      }
      // consume OTP
      _dbDeleteOtp(phone);
      final found = user!;
      final tokens = _issueTokens(found['id'] as String, found['email'] as String?);
      return Response.ok(jsonEncode({'token': tokens['accessToken'], 'refreshToken': tokens['refreshToken'], 'user': {'id': found['id'], 'phone': found['phone'], 'email': found['email']}}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ Error in verify-otp: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Verify email OTP for login or registration with password
  router.post('/api/auth/verify-email-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      // ✅ FIX: Handle code as integer or string from JSON
      var codeValue = data['code'];
      String? code;
      if (codeValue != null) {
        if (codeValue is String) {
          code = codeValue.trim();
        } else if (codeValue is int) {
          code = codeValue.toString();
        } else {
          code = codeValue.toString().trim();
        }
      }
      final password = data['password'] as String?;
      final username = (data['username'] as String?)?.trim();
      
      print('[EMAIL OTP] Verify attempt: email=$email, code=$code, hasPassword=${password != null}, username=$username');
      
      if (email == null || code == null) {
        return Response(400, body: jsonEncode({'error': 'Missing email or code'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Check OTP
      final record = _dbGetEmailOtp(email);
      print('[EMAIL OTP] OTP record found: ${record != null ? '✅ YES' : '❌ NO'}');
      if (record != null) print('   Stored OTP: ${record['code']}, Provided: $code');
      
      if (record == null) {
        return Response(400, body: jsonEncode({'error': 'No OTP requested'}), headers: {'Content-Type': 'application/json'});
      }
      
      final expires = DateTime.parse(record['expiresAt'] as String);
      if (DateTime.now().isAfter(expires)) {
        print('[EMAIL OTP] ⏰ OTP expired');
        return Response(400, body: jsonEncode({'error': 'OTP expired'}), headers: {'Content-Type': 'application/json'});
      }
      
      var storedCode = record['code'];
      // ✅ FIX: Ensure stored code is also a string
      if (storedCode is! String) {
        storedCode = storedCode.toString();
      }
      storedCode = (storedCode as String).trim();
      
      print('[EMAIL OTP] 🔍 Code Comparison:');
      print('[EMAIL OTP]   Stored: "$storedCode" (length=${storedCode.length})');
      print('[EMAIL OTP]   Provided: "$code" (length=${code.length})');
      print('[EMAIL OTP]   Match: ${storedCode == code}');
      
      if (storedCode != code) {
        print('[EMAIL OTP] ❌ Code mismatch: "$storedCode" != "$code"');
        final attempts = (record['attempts'] as int? ?? 0) + 1;
        _dbSaveEmailOtp(email, storedCode, record['expiresAt'] as String, attempts);
        return Response(401, body: jsonEncode({'error': 'Invalid OTP code'}), headers: {'Content-Type': 'application/json'});
      }
      
      print('[EMAIL OTP] ✅ OTP verified successfully');
      
      // Check if this is for login (user exists) or registration (user doesn't exist)
      var user = await _dbGetUserByEmail(email);
      
      if (user != null) {
        // LOGIN: User exists, verify password
        if (password == null) {
          return Response(400, body: jsonEncode({'error': 'Password required for login'}), headers: {'Content-Type': 'application/json'});
        }
        
        final hash = user['password_hash'] as String?;
        if (hash == null) {
          return Response(401, body: jsonEncode({'error': 'Account has no password set'}), headers: {'Content-Type': 'application/json'});
        }
        
        final passwordValid = BCrypt.checkpw(password, hash);
        if (!passwordValid) {
          return Response(401, body: jsonEncode({'error': 'Invalid password'}), headers: {'Content-Type': 'application/json'});
        }
        
        print('[EMAIL OTP] 🔐 Password verified for existing user');
        
      } else {
        // REGISTRATION: Create new user
        if (password == null || password.length < 6) {
          return Response(400, body: jsonEncode({'error': 'Password must be at least 6 characters'}), headers: {'Content-Type': 'application/json'});
        }
        
        final newId = uuid.v4();
        final createdAt = DateTime.now().toIso8601String();
        final hash = BCrypt.hashpw(password, BCrypt.gensalt());
        final defaultUsername = username ?? email.split('@')[0];
        
        await _dbInsertUser(
          id: newId, 
          email: email, 
          password_hash: hash, 
          phone: null, 
          google_id: null, 
          created_at: createdAt,
          username: defaultUsername
        );
        
        user = await _dbGetUserById(newId);
        print('[EMAIL OTP] 👤 New user created: $newId with username: $defaultUsername');
      }
      
      // Consume OTP
      _dbDeleteEmailOtp(email);
      
      // Issue tokens
      final found = user!;
      final tokens = _issueTokens(found['id'] as String, found['email'] as String?);
      
      return Response.ok(jsonEncode({
        'token': tokens['accessToken'], 
        'accessToken': tokens['accessToken'], 
        'refreshToken': tokens['refreshToken'], 
        'user': {
          'id': found['id'], 
          'email': found['email'], 
          'phone': found['phone'],
          'username': found['username']
        }
      }), headers: {'Content-Type': 'application/json'});
      
    } catch (e) {
      print('[EMAIL OTP] ❌ Error: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Google token verification (id_token) - verify with Google's tokeninfo endpoint
  router.post('/api/auth/google', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final idToken = data['idToken'] as String?;
      if (idToken == null) return Response(400, body: jsonEncode({'error': 'Missing idToken'}), headers: {'Content-Type': 'application/json'});
      final verifyUri = Uri.parse('https://oauth2.googleapis.com/tokeninfo?id_token=$idToken');
      final resp = await http.get(verifyUri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return Response(401, body: jsonEncode({'error': 'Invalid Google token', 'raw': resp.body}), headers: {'Content-Type': 'application/json'});
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      // decoded contains 'email', 'sub' (user id), 'email_verified'
      final email = (decoded['email'] as String?)?.toLowerCase();
      final googleId = decoded['sub'] as String?;
      if (email == null || googleId == null) return Response(400, body: jsonEncode({'error': 'Invalid token payload'}), headers: {'Content-Type': 'application/json'});
      // find or create user by email
      var user = await _dbGetUserByEmail(email);
      if (user == null) {
        final newId = uuid.v4();
        final createdAt = DateTime.now().toIso8601String();
        await _dbInsertUser(id: newId, email: email, password_hash: null, phone: null, google_id: googleId, created_at: createdAt);
        user = await _dbGetUserById(newId);
      } else {
        // ensure google id is stored/updated
  final found = user;
  _dbUpdateGoogleId(found['id'] as String, googleId);
  user = await _dbGetUserById(found['id'] as String);
      }
      final tokens = _issueTokens(user!['id'] as String, email);
      return Response.ok(jsonEncode({'token': tokens['accessToken'], 'refreshToken': tokens['refreshToken'], 'user': {'id': user['id'], 'email': user['email']}}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Refresh access token using refresh token
  router.post('/api/auth/refresh', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final refreshToken = data['refreshToken'] as String?;
      if (refreshToken == null) return Response(400, body: jsonEncode({'error': 'Missing refreshToken'}), headers: {'Content-Type': 'application/json'});
      
      final session = _dbGetSessionByRefreshToken(refreshToken);
      if (session == null) return Response(401, body: jsonEncode({'error': 'Invalid or revoked refresh token'}), headers: {'Content-Type': 'application/json'});
      
      final expiresAt = DateTime.parse(session['expiresAt'] as String);
      if (DateTime.now().isAfter(expiresAt)) return Response(401, body: jsonEncode({'error': 'Refresh token expired'}), headers: {'Content-Type': 'application/json'});
      
      final userId = session['userId'] as String;
      final user = await _dbGetUserById(userId);
      if (user == null) return Response(401, body: jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      
      // Check if user is an admin (has admin passkey)
      final isAdmin = (user['admin_passkey'] as String?) != null;
      final role = isAdmin ? 'admin' : 'user';
      
      // Issue new tokens and create new session with correct role
      final tokens = _issueTokens(userId, user['email'] as String?, role: role);
      return Response.ok(jsonEncode({'token': tokens['accessToken'], 'refreshToken': tokens['refreshToken']}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Revoke refresh token (logout)
  router.post('/api/auth/revoke', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final refreshToken = data['refreshToken'] as String?;
      if (refreshToken == null) return Response(400, body: jsonEncode({'error': 'Missing refreshToken'}), headers: {'Content-Type': 'application/json'});
      
      _dbRevokeSession(refreshToken);
      return Response.ok(jsonEncode({'success': true}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Get user profile
  router.get('/api/user/profile', (Request request) async {
    try {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      final token = authHeader.substring(7);
      
      final userId = _verifyJWT(token);
      if (userId == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      
      final user = await _dbGetUserById(userId);
      if (user == null) {
        return Response(404, body: jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      }
      
      return Response.ok(jsonEncode({
        'email': user['email'],
        'username': user['username'] ?? '',
        'createdAt': user['created_at'],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('[PROFILE] Error: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Update user profile (username only for now)
  router.put('/api/user/profile', (Request request) async {
    try {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      final token = authHeader.substring(7);
      
      final userId = _verifyJWT(token);
      if (userId == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      
      final body = await request.readAsString();
      print('[UPDATE PROFILE] Received update request: $body');
      final data = jsonDecode(body) as Map<String, dynamic>;
      final username = data['username'] as String?;
      
      if (username == null || username.trim().isEmpty) {
        return Response(400, body: jsonEncode({'error': 'Username is required'}), headers: {'Content-Type': 'application/json'});
      }
      
      final trimmedUsername = username.trim();
      
      // Check if username is already taken by another user
      final existingUser = db.select('SELECT id FROM users WHERE username = ? AND id != ?', [trimmedUsername, userId]);
      if (existingUser.isNotEmpty) {
        return Response(400, body: jsonEncode({'error': 'Username is already taken'}), headers: {'Content-Type': 'application/json'});
      }
      
      // Update username
      db.execute('UPDATE users SET username = ? WHERE id = ?', [trimmedUsername, userId]);
      print('[UPDATE PROFILE] ✅ Updated username for user $userId to: $trimmedUsername');
      
      return Response.ok(jsonEncode({
        'success': true,
        'username': trimmedUsername
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('[UPDATE PROFILE] Error: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Dev-only: return list of users from DB for integration tests/debugging
  router.get('/internal/debug/users', (Request request) {
    final allow = (Platform.environment['DEV_ALLOW_DEBUG'] ?? _readLocalEnvTop('DEV_ALLOW_DEBUG') ?? '').toLowerCase();
    if (!(allow == '1' || allow == 'true' || allow == 'yes')) {
      return Response.forbidden(jsonEncode({'error': 'Debug endpoint disabled'}), headers: {'Content-Type': 'application/json'});
    }
    try {
      if (!dbAvailable) {
        return Response.ok(jsonEncode({'users': usersCache}), headers: {'Content-Type': 'application/json'});
      }
      final rows = db.select('SELECT id, email, phone, google_id, created_at FROM users;');
      final out = rows.map((r) => {
        'id': r['id'],
        'email': r['email'],
        'phone': r['phone'],
        'googleId': r['google_id'],
        'createdAt': r['created_at'],
      }).toList();
      return Response.ok(jsonEncode({'users': out}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Get all contributions (public - only approved)
  router.get('/api/contributions', (Request request) async {
    if (contribCollection == null) {
      return Response.ok(
        jsonEncode([]),
        headers: {'Content-Type': 'application/json'},
      );
    }
    // Return ALL contributions (both approved and pending) for community section
    // Community section will display pending with status badge, approved without badge
    final all = await contribCollection?.find().toList() ?? [];
    
    // Remove authorEmail from response to protect user privacy
    final sanitized = all.map((contrib) {
      contrib.remove('authorEmail');
      return contrib;
    }).toList();
    
    return Response.ok(
      jsonEncode(sanitized),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Public stats endpoint (no authentication required)
  router.get('/api/stats/public', (Request request) async {
    try {
      print('🔵 [PUBLIC_STATS] Fetching platform statistics');
      
      // Get total users from MongoDB (excluding admin)
      int totalUsers = 0;
      try {
        if (mongoUsersCollection != null) {
          // Count users without admin_passkey (regular users)
          totalUsers = await mongoUsersCollection!.count(where.eq('admin_passkey', null));
          print('📊 [PUBLIC_STATS] Found $totalUsers regular users (excluding admin)');
        }
      } catch (e) {
        print('⚠️ Could not count users: $e');
      }

      // Get contribution stats
      int totalContributions = 0;
      int pendingContributions = 0;
      int approvedContributions = 0;
      int rejectedContributions = 0;

      if (contribCollection != null) {
        try {
          final allContribs = await contribCollection?.find().toList() ?? [];
          totalContributions = allContribs.length;
          
          final pending = await contribCollection?.find({'status': 'pending'}).toList() ?? [];
          pendingContributions = pending.length;
          
          final approved = await contribCollection?.find({'status': 'approved'}).toList() ?? [];
          approvedContributions = approved.length;
          
          final rejected = await contribCollection?.find({'status': 'rejected'}).toList() ?? [];
          rejectedContributions = rejected.length;
        } catch (e) {
          print('⚠️ Could not get contribution stats: $e');
        }
      }

      final stats = {
        'totalUsers': totalUsers,
        'totalContributions': totalContributions,
        'pendingContributions': pendingContributions,
        'approvedContributions': approvedContributions,
        'rejectedContributions': rejectedContributions,
        'timestamp': DateTime.now().toIso8601String(),
      };

      print('✅ [PUBLIC_STATS] Stats: $stats');
      return Response.ok(jsonEncode(stats), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ [PUBLIC_STATS] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // QUIZ & CHALLENGE ROUTES START
  
  // Submit quiz result (authenticated users)
  router.post('/api/quiz-results', (Request request) async {
    try {
      if (quizResultsCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'Quiz results feature unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response.forbidden(jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      
      final token = authHeader.substring(7);
      final userId = _verifyJWT(token);
      if (userId == null) {
        return Response.unauthorized(jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      
      final user = await _dbGetUserById(userId);
      if (user == null) {
        return Response.forbidden(jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      }
      
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;
      
      // Add user information and timestamp
      data['userId'] = userId;
      data['userEmail'] = user['email'];
      data['username'] = user['username'] ?? 'Unknown';
      data['submittedAt'] = DateTime.now().toIso8601String();
      
      // Validate required fields
      if (!data.containsKey('quizId') || !data.containsKey('score') || !data.containsKey('totalQuestions')) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Missing required fields: quizId, score, totalQuestions'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      
      final result = await quizResultsCollection?.insertOne(data);
      print('✅ [QUIZ_RESULT] Saved: ${user['username']} scored ${data['score']}/${data['totalQuestions']}');
      
      return Response.ok(
        jsonEncode({'success': result?.isSuccess ?? false, 'id': result?.id?.toHexString()}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [QUIZ_RESULT] Error: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to save quiz result: $e'}),
      );
    }
  });

  // Get aggregated quiz statistics (public endpoint for leaderboard)
  router.get('/api/quiz-results/leaderboard', (Request request) async {
    try {
      if (quizResultsCollection == null) {
        return Response.ok(jsonEncode([]), headers: {'Content-Type': 'application/json'});
      }
      
      // Aggregate quiz results by user
      final pipeline = [
        {
          '\$group': {
            '_id': '\$userEmail',
            'username': {'\$first': '\$username'},
            'totalQuizzes': {'\$sum': 1},
            'totalScore': {'\$sum': '\$score'},
            'totalQuestions': {'\$sum': '\$totalQuestions'},
            'highestScore': {'\$max': '\$score'},
          }
        },
        {
          '\$project': {
            '_id': 0,
            'userEmail': '\$_id',
            'username': 1,
            'totalQuizzes': 1,
            'totalScore': 1,
            'totalQuestions': 1,
            'averagePercentage': {
              '\$cond': [
                {'\$eq': ['\$totalQuestions', 0]},
                0,
                {'\$multiply': [{'\$divide': ['\$totalScore', '\$totalQuestions']}, 100]}
              ]
            },
            'highestScore': 1,
          }
        },
        {'\$sort': {'averagePercentage': -1}},
        {'\$limit': 50} // Top 50 users
      ];
      
      final results = await quizResultsCollection?.aggregateToStream(pipeline).toList() ?? [];
      print('✅ [QUIZ_LEADERBOARD] Fetched ${results.length} users');
      
      return Response.ok(jsonEncode(results), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ [QUIZ_LEADERBOARD] Error: $e');
      return Response.ok(jsonEncode([]), headers: {'Content-Type': 'application/json'});
    }
  });

  // Submit daily challenge result (authenticated users)
  router.post('/api/challenge-results', (Request request) async {
    try {
      if (challengeResultsCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'Challenge results feature unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response.forbidden(jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      
      final token = authHeader.substring(7);
      final userId = _verifyJWT(token);
      if (userId == null) {
        return Response.unauthorized(jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      
      final user = await _dbGetUserById(userId);
      if (user == null) {
        return Response.forbidden(jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      }
      
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;
      
      // Add user information and timestamp
      data['userId'] = userId;
      data['userEmail'] = user['email'];
      data['username'] = user['username'] ?? 'Unknown';
      data['submittedAt'] = DateTime.now().toIso8601String();
      
      // Validate required fields
      if (!data.containsKey('challengeId') || !data.containsKey('completed')) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Missing required fields: challengeId, completed'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      
      final result = await challengeResultsCollection?.insertOne(data);
      print('✅ [CHALLENGE_RESULT] Saved: ${user['username']} - Challenge ${data['challengeId']} - Won: ${data['wonPrize'] ?? false}');
      
      return Response.ok(
        jsonEncode({'success': result?.isSuccess ?? false, 'id': result?.id?.toHexString()}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [CHALLENGE_RESULT] Error: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to save challenge result: $e'}),
      );
    }
  });

  // Get challenge statistics (public endpoint for leaderboard)
  router.get('/api/challenge-results/leaderboard', (Request request) async {
    try {
      if (challengeResultsCollection == null) {
        return Response.ok(jsonEncode([]), headers: {'Content-Type': 'application/json'});
      }
      
      // Aggregate challenge results by user
      final pipeline = [
        {
          '\$group': {
            '_id': '\$userEmail',
            'username': {'\$first': '\$username'},
            'totalChallenges': {'\$sum': 1},
            'completedChallenges': {
              '\$sum': {
                '\$cond': [{'\$eq': ['\$completed', true]}, 1, 0]
              }
            },
            'prizesWon': {
              '\$sum': {
                '\$cond': [{'\$eq': ['\$wonPrize', true]}, 1, 0]
              }
            },
            'totalPoints': {'\$sum': {'\$ifNull': ['\$points', 0]}},
          }
        },
        {
          '\$project': {
            '_id': 0,
            'userEmail': '\$_id',
            'username': 1,
            'totalChallenges': 1,
            'completedChallenges': 1,
            'prizesWon': 1,
            'totalPoints': 1,
          }
        },
        {'\$sort': {'prizesWon': -1, 'totalPoints': -1}},
        {'\$limit': 50} // Top 50 users
      ];
      
      final results = await challengeResultsCollection?.aggregateToStream(pipeline).toList() ?? [];
      print('✅ [CHALLENGE_LEADERBOARD] Fetched ${results.length} users');
      
      return Response.ok(jsonEncode(results), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ [CHALLENGE_LEADERBOARD] Error: $e');
      return Response.ok(jsonEncode([]), headers: {'Content-Type': 'application/json'});
    }
  });

  // Get combined leaderboard (contributions + quizzes + challenges)
  router.get('/api/leaderboard/top-contributors', (Request request) async {
    try {
      print('📊 [TOP_CONTRIBUTORS] Fetching combined leaderboard');
      
      final Map<String, Map<String, dynamic>> userScores = {};
      
      // 1. Get contributions (weight: 50%)
      if (contribCollection != null) {
        final contributions = await contribCollection?.find({'status': 'approved'}).toList() ?? [];
        for (final contrib in contributions) {
          final email = contrib['authorEmail']?.toString() ?? '';
          final username = contrib['authorName']?.toString() ?? contrib['authorUsername']?.toString() ?? '';
          
          if (email.isNotEmpty) {
            if (!userScores.containsKey(email)) {
              userScores[email] = {
                'email': email,
                'username': username,
                'contributions': 0,
                'quizScore': 0.0,
                'challengePrizes': 0,
                'totalScore': 0.0,
              };
            }
            userScores[email]!['contributions'] = (userScores[email]!['contributions'] as int) + 1;
          }
        }
      }
      
      // 2. Get quiz results (weight: 30%)
      if (quizResultsCollection != null) {
        final pipeline = [
          {
            '\$group': {
              '_id': '\$userEmail',
              'username': {'\$first': '\$username'},
              'avgPercentage': {
                '\$avg': {
                  '\$multiply': [
                    {'\$divide': ['\$score', '\$totalQuestions']},
                    100
                  ]
                }
              }
            }
          }
        ];
        final quizResults = await quizResultsCollection?.aggregateToStream(pipeline).toList() ?? [];
        for (final result in quizResults) {
          final email = result['_id']?.toString() ?? '';
          final username = result['username']?.toString() ?? '';
          final avgPercentage = (result['avgPercentage'] as num?)?.toDouble() ?? 0.0;
          
          if (email.isNotEmpty) {
            if (!userScores.containsKey(email)) {
              userScores[email] = {
                'email': email,
                'username': username,
                'contributions': 0,
                'quizScore': 0.0,
                'challengePrizes': 0,
                'totalScore': 0.0,
              };
            }
            userScores[email]!['quizScore'] = avgPercentage;
            if (username.isNotEmpty && userScores[email]!['username'].toString().isEmpty) {
              userScores[email]!['username'] = username;
            }
          }
        }
      }
      
      // 3. Get challenge results (weight: 20%)
      if (challengeResultsCollection != null) {
        final pipeline = [
          {
            '\$group': {
              '_id': '\$userEmail',
              'username': {'\$first': '\$username'},
              'prizesWon': {
                '\$sum': {
                  '\$cond': [{'\$eq': ['\$wonPrize', true]}, 1, 0]
                }
              }
            }
          }
        ];
        final challengeResults = await challengeResultsCollection?.aggregateToStream(pipeline).toList() ?? [];
        for (final result in challengeResults) {
          final email = result['_id']?.toString() ?? '';
          final username = result['username']?.toString() ?? '';
          final prizesWon = (result['prizesWon'] as int?) ?? 0;
          
          if (email.isNotEmpty) {
            if (!userScores.containsKey(email)) {
              userScores[email] = {
                'email': email,
                'username': username,
                'contributions': 0,
                'quizScore': 0.0,
                'challengePrizes': 0,
                'totalScore': 0.0,
              };
            }
            userScores[email]!['challengePrizes'] = prizesWon;
            if (username.isNotEmpty && userScores[email]!['username'].toString().isEmpty) {
              userScores[email]!['username'] = username;
            }
          }
        }
      }
      
      // Calculate weighted scores
      for (final entry in userScores.entries) {
        final contributions = entry.value['contributions'] as int;
        final quizScore = entry.value['quizScore'] as double;
        final prizes = entry.value['challengePrizes'] as int;
        
        // Weighted formula: contributions (10 pts each, 50%) + quiz avg (30%) + prizes (20 pts each, 20%)
        final totalScore = (contributions * 10 * 0.5) + (quizScore * 0.3) + (prizes * 20 * 0.2);
        entry.value['totalScore'] = totalScore;
      }
      
      // Sort by total score and take top 10
      final sortedUsers = userScores.values.toList()
        ..sort((a, b) => (b['totalScore'] as double).compareTo(a['totalScore'] as double));
      
      final top10 = sortedUsers.take(10).toList();
      
      print('✅ [TOP_CONTRIBUTORS] Returning ${top10.length} top users');
      return Response.ok(jsonEncode(top10), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('❌ [TOP_CONTRIBUTORS] Error: $e');
      return Response.ok(jsonEncode([]), headers: {'Content-Type': 'application/json'});
    }
  });

  // ADMIN ROUTES START
  router.get('/api/admin/ping', (Request request) async {
    final auth = request.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
    if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
    return Response.ok(jsonEncode({'ok': true}), headers: {'Content-Type':'application/json'});
  });
  router.get('/api/admin/contributions', (Request request) async {
    final auth = request.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
    
    final token = auth.substring(7);
    print('🔍 [ADMIN_CONTRIBUTIONS] Checking admin token');
    
    if (!_isAdminToken(token)) {
      print('❌ [ADMIN_CONTRIBUTIONS] Admin token check failed');
      return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
    }
    
    print('✅ [ADMIN_CONTRIBUTIONS] Admin token verified');
    
    if (contribCollection == null) return Response.ok(jsonEncode([]), headers: {'Content-Type':'application/json'});
    
    // Build filter query from query parameters
    final filter = <String, dynamic>{};
    final status = request.url.queryParameters['status'];
    final category = request.url.queryParameters['category'];
    final type = request.url.queryParameters['type'];
    
    print('🔍 [ADMIN_CONTRIBUTIONS] Filters - status: $status, category: $category, type: $type');
    
    if (status != null && status != 'all') {
      filter['status'] = status;
    }
    if (category != null && category != 'all') {
      filter['category'] = category;
    }
    if (type != null && type != 'all') {
      filter['type'] = type;
    }
    
    final list = await contribCollection!.find(filter).toList();
    print('📊 [ADMIN_CONTRIBUTIONS] Found ${list.length} contributions');
    return Response.ok(jsonEncode(list), headers: {'Content-Type':'application/json'});
  });
  router.get('/api/admin/users', (Request request) async {
    final auth = request.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
    if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
    
    final out = <Map<String, dynamic>>[];
    final processedEmails = <String>{}; // Track processed users to avoid duplicates
    // Extract current admin email from token so we can exclude admin from both MongoDB and SQLite results
    final token = auth.substring(7);
    String? currentAdminEmail;
    try {
      final decoded = JWT.verify(token, SecretKey(jwtSecret));
      currentAdminEmail = decoded.payload['email'] as String?;
      print('[ADMIN] 👮 Current admin: $currentAdminEmail');
    } catch (e) {
      print('[ADMIN] ⚠️ Could not decode token: $e');
    }
    
    // Query MongoDB first (production) - Get ALL users except current admin
    if (mongoUsersCollection != null) {
      try {
        print('[ADMIN] 🔍 Querying MongoDB for ALL users (admin excluded)...');
        
        // Get admin email from token to exclude current admin
        final token = auth.substring(7);
        String? currentAdminEmail;
        try {
          final decoded = JWT.verify(token, SecretKey(jwtSecret));
          currentAdminEmail = decoded.payload['email'] as String?;
          print('[ADMIN] 👮 Current admin: $currentAdminEmail');
        } catch (e) {
          print('[ADMIN] ⚠️ Could not decode token: $e');
        }
        
        // Query ALL users from MongoDB
        final cursor = mongoUsersCollection!.find();
        final mongoUsers = await cursor.toList();
        
        print('[ADMIN] 📊 Found ${mongoUsers.length} total users in MongoDB');
        
        // Get contribution count from MongoDB for each user
        for (final mongoUser in mongoUsers) {
          final userEmail = mongoUser['email'] as String?;
          final userId = mongoUser['id'] as String?;
          
          // Skip if already processed or missing fields
          if (userEmail == null || userId == null || processedEmails.contains(userEmail)) {
            continue;
          }
          
          // Skip current admin from the list (admin can't manage themselves)
          if (currentAdminEmail != null && userEmail.toLowerCase() == currentAdminEmail.toLowerCase()) {
            print('[ADMIN] 👮 Skipping current admin: $userEmail');
            continue;
          }
          
          // Count contributions by authorEmail
          final count = await contribCollection?.count({'authorEmail': userEmail}) ?? 0;
          out.add({
            'id': userId,
            'email': userEmail,
            'username': mongoUser['username'] as String? ?? userEmail.split('@')[0],
            'createdAt': mongoUser['created_at'] as String?,
            'contributionCount': count,
          });
          processedEmails.add(userEmail);
          print('[ADMIN] 👤 User $userEmail (ID: $userId) has $count contributions');
        }
      } catch (e) {
        print('[ADMIN] ❌ MongoDB query error: $e');
        print('[ADMIN] Stack trace: ${StackTrace.current}');
        // Don't return error, try SQLite fallback below
      }
    }
    
    // Merge SQLite rows into the results to ensure no local users are missed
    // (MongoDB may be partial or missing migrated rows)
    try {
      print('[ADMIN] 🔁 Merging local SQLite users (if any)');
      final rows = db.select('SELECT id, email, username, created_at FROM users');
      for (final r in rows) {
        final email = r['email'] as String?;
        if (email == null) continue;
        // Skip current admin and duplicates already processed from MongoDB
        if (processedEmails.contains(email)) continue;
        if (currentAdminEmail != null && email.toLowerCase() == currentAdminEmail.toLowerCase()) continue;

        final id = r['id'] as String?;
        final username = r['username'] as String? ?? email.split('@')[0];
        final createdAt = r['created_at'] as String?;
        final count = await contribCollection?.count({'authorEmail': email}) ?? 0;

        out.add({
          'id': id ?? uuid.v4(),
          'email': email,
          'username': username,
          'createdAt': createdAt,
          'contributionCount': count,
        });
        processedEmails.add(email);
        print('[ADMIN] 🗂️ Merged SQLite user $email (ID: ${id ?? 'generated'})');
      }
    } catch (e) {
      print('[ADMIN] ⚠️ SQLite merge error: $e');
    }
    
    print('[ADMIN] 📊 Returning ${out.length} users to admin panel');
    return Response.ok(jsonEncode(out), headers: {'Content-Type':'application/json'});
  });

  // Get individual user details with contribution count
  router.get('/api/admin/users/<userId>', (Request request, String userId) async {
    try {
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
      if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
      
      // Get user from SQLite
      final rows = db.select('SELECT id, email, username, created_at FROM users WHERE id = ? AND admin_passkey IS NULL', [userId]);
      if (rows.isEmpty) {
        return Response.notFound(jsonEncode({'error': 'User not found'}), headers: {'Content-Type':'application/json'});
      }
      
      final user = rows.first;
      final userEmail = user['email'] as String;
      // Count contributions by authorEmail (which is how they're stored in MongoDB)
      final count = (contribCollection != null) ? await contribCollection?.count({'authorEmail': userEmail}) ?? 0 : 0;
      
      final userData = {
        'id': user['id'],
        'email': userEmail,
        'username': user['username'],
        'createdAt': user['created_at'],
        'contributionCount': count,
      };
      
      print('[ADMIN] 📋 Retrieved user details for $userId ($userEmail): $count contributions');
      return Response.ok(jsonEncode(userData), headers: {'Content-Type':'application/json'});
    } catch (e) {
      print('[ADMIN] ❌ Error getting user details: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Error: $e'}), headers: {'Content-Type':'application/json'});
    }
  });

  // Delete user and all their data (contributions, quiz/challenge results, sessions, OTPs)
  router.delete('/api/admin/users/<userId>', (Request request, String userId) async {
    try {
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
      if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
      
      print('[ADMIN] 🗑️ Starting CASCADE deletion for user: $userId');
      
      // Get user first to verify they exist (try MongoDB first, then SQLite)
      String? userEmail;
      
      if (mongoUsersCollection != null) {
        try {
          final mongoUser = await mongoUsersCollection!.findOne(where.eq('id', userId));
          if (mongoUser != null && mongoUser['admin_passkey'] == null) {
            userEmail = mongoUser['email'] as String?;
          }
        } catch (e) {
          print('[ADMIN] ⚠️ MongoDB user lookup failed: $e');
        }
      }
      
      // Fallback to SQLite if MongoDB failed or user not found
      if (userEmail == null) {
        final rows = db.select('SELECT id, email FROM users WHERE id = ? AND admin_passkey IS NULL', [userId]);
        if (rows.isEmpty) {
          print('[ADMIN] ❌ User not found: $userId');
          return Response.notFound(jsonEncode({'error': 'User not found'}), headers: {'Content-Type':'application/json'});
        }
        userEmail = rows.first['email'] as String;
      }
      
      print('[ADMIN] 📧 Deleting all data for: $userEmail ($userId)');
      
      var deletedItems = <String, int>{};
      
      // 1. KEEP contributions when user is deleted (community content persists)
      // Contributions remain in database even after user deletion
      // Only admin can delete approved contributions from the community section
      if (contribCollection != null) {
        try {
          final userContribs = await contribCollection!.find(where.eq('authorEmail', userEmail)).toList();
          deletedItems['contributions'] = userContribs.length;
          print('[ADMIN] ℹ️  User has ${deletedItems['contributions']} contributions that will remain in community');
        } catch (e) {
          print('[ADMIN] ⚠️ Error counting contributions: $e');
          deletedItems['contributions'] = 0;
        }
      }
      
      // 2. Delete all quiz results by this user (stored by userId and userEmail)
      if (quizResultsCollection != null) {
        try {
          final quizResult = await quizResultsCollection!.deleteMany(where.eq('userId', userId));
          deletedItems['quizResults'] = quizResult.nRemoved;
          print('[ADMIN] 🗑️ Deleted ${deletedItems['quizResults']} quiz results');
        } catch (e) {
          print('[ADMIN] ⚠️ Error deleting quiz results: $e');
          deletedItems['quizResults'] = 0;
        }
      }
      
      // 3. Delete all challenge results by this user (stored by userId and userEmail)
      if (challengeResultsCollection != null) {
        try {
          final challengeResult = await challengeResultsCollection!.deleteMany(where.eq('userId', userId));
          deletedItems['challengeResults'] = challengeResult.nRemoved;
          print('[ADMIN] 🗑️ Deleted ${deletedItems['challengeResults']} challenge results');
        } catch (e) {
          print('[ADMIN] ⚠️ Error deleting challenge results: $e');
          deletedItems['challengeResults'] = 0;
        }
      }
      
      // 4. Delete all sessions by this user
      if (mongoSessionsCollection != null) {
        try {
          final sessionResult = await mongoSessionsCollection!.deleteMany(where.eq('userId', userId));
          deletedItems['sessions'] = sessionResult.nRemoved;
          print('[ADMIN] 🗑️ Deleted ${deletedItems['sessions']} sessions');
        } catch (e) {
          print('[ADMIN] ⚠️ Error deleting sessions: $e');
          deletedItems['sessions'] = 0;
        }
      }
      
      // 5. Delete all email OTPs for this user
      if (mongoEmailOtpsCollection != null) {
        try {
          final otpResult = await mongoEmailOtpsCollection!.deleteMany(where.eq('email', userEmail));
          deletedItems['emailOtps'] = otpResult.nRemoved;
          print('[ADMIN] 🗑️ Deleted ${deletedItems['emailOtps']} email OTPs');
        } catch (e) {
          print('[ADMIN] ⚠️ Error deleting email OTPs: $e');
          deletedItems['emailOtps'] = 0;
        }
      }
      
      // 6. Delete user from MongoDB (primary database)
      if (mongoUsersCollection != null) {
        try {
          final userResult = await mongoUsersCollection!.deleteOne(where.eq('id', userId));
          print('[ADMIN] 🗑️ Deleted user from MongoDB: ${userResult.nRemoved} document(s)');
        } catch (e) {
          print('[ADMIN] ⚠️ Error deleting user from MongoDB: $e');
        }
      }
      
      // 7. Delete user from SQLite (fallback/cache)
      try {
        db.execute('DELETE FROM users WHERE id = ?', [userId]);
        db.execute('DELETE FROM sessions WHERE user_id = ?', [userId]);
        db.execute('DELETE FROM email_otps WHERE email = ?', [userEmail]);
        print('[ADMIN] 🗑️ Deleted user from SQLite cache');
      } catch (e) {
        print('[ADMIN] ⚠️ Error deleting from SQLite: $e');
      }
      
      // 8. Remove from in-memory cache
      try {
        usersCache.removeWhere((u) => u['id'] == userId);
        print('[ADMIN] 🗑️ Removed user from in-memory cache');
      } catch (e) {
        print('[ADMIN] ⚠️ Error removing from cache: $e');
      }
      
      print('[ADMIN] ✅ CASCADE deletion complete for: $userEmail ($userId)');
      print('[ADMIN] 📊 Deleted: ${deletedItems.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
      
      return Response.ok(jsonEncode({
        'success': true, 
        'message': 'User and all associated data deleted successfully',
        'userEmail': userEmail,
        'deletedItems': deletedItems,
      }), headers: {'Content-Type':'application/json'});
    } catch (e) {
      print('[ADMIN] ❌ Error deleting user: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Error: $e'}), headers: {'Content-Type':'application/json'});
    }
  });

  // Update contribution status (PATCH) - admin only
  router.patch('/api/admin/contributions/<id>/status', (Request request, String id) async {
    try {
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
      if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
      
      if (contribCollection == null) {
        return Response(503, body: jsonEncode({'error': 'MongoDB connection unavailable'}), headers: {'Content-Type': 'application/json'});
      }

      ObjectId docId;
      try {
        docId = ObjectId.parse(id);
      } catch (e) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid document ID format'}));
      }

      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      final adminNote = data['adminNote'] as String?;

      if (status == null) {
        return Response.badRequest(body: jsonEncode({'error': 'Status is required'}));
      }

      final doc = await contribCollection?.findOne({'_id': docId});
      if (doc == null) {
        return Response.notFound(jsonEncode({'error': 'Contribution not found'}));
      }

      final updateData = <String, dynamic>{'status': status};
      if (adminNote != null) {
        updateData['adminNote'] = adminNote;
      }

      await contribCollection?.updateOne({'_id': docId}, {'\$set': updateData});
      print('✅ [ADMIN] Contribution $id status updated to $status');

      return Response.ok(
        jsonEncode({'success': true, 'status': status}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [ADMIN] Error updating status: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Failed to update contribution: $e'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Delete contribution - admin only
  router.delete('/api/admin/contributions/<id>', (Request request, String id) async {
    try {
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
      if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
      
      if (contribCollection == null) {
        return Response(503, body: jsonEncode({'error': 'MongoDB connection unavailable'}), headers: {'Content-Type': 'application/json'});
      }

      ObjectId docId;
      try {
        docId = ObjectId.parse(id);
      } catch (e) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid document ID format'}));
      }

      final doc = await contribCollection?.findOne({'_id': docId});
      if (doc == null) {
        return Response.notFound(jsonEncode({'error': 'Contribution not found'}));
      }

      await contribCollection?.deleteOne({'_id': docId});

      print('✅ [ADMIN] Contribution $id deleted');
      return Response.ok(
        jsonEncode({'success': true}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [ADMIN] Error deleting contribution: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Failed to delete contribution: $e'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Bulk approve contributions - admin only
  router.post('/api/admin/contributions/bulk-approve', (Request request) async {
    try {
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
      if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
      
      if (contribCollection == null) {
        return Response(503, body: jsonEncode({'error': 'MongoDB connection unavailable'}), headers: {'Content-Type': 'application/json'});
      }

      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final ids = (data['ids'] as List<dynamic>?)?.cast<String>() ?? [];

      if (ids.isEmpty) {
        return Response.badRequest(body: jsonEncode({'error': 'No IDs provided'}));
      }

      int approvedCount = 0;
      for (final id in ids) {
        try {
          final docId = ObjectId.parse(id);
          await contribCollection?.updateOne(
            {'_id': docId},
            {'\$set': {'status': 'approved'}}
          );
          approvedCount++;
        } catch (e) {
          print('❌ [ADMIN] Error approving $id: $e');
        }
      }

      print('✅ [ADMIN] Approved $approvedCount contributions');
      return Response.ok(
        jsonEncode({'success': true, 'approvedCount': approvedCount}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [ADMIN] Error in bulk approve: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Failed to approve contributions: $e'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Bulk delete contributions - admin only
  router.post('/api/admin/contributions/bulk-delete', (Request request) async {
    try {
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) return Response(401, body: jsonEncode({'error':'Unauthorized'}), headers: {'Content-Type':'application/json'});
      if (!_isAdminToken(auth.substring(7))) return Response(403, body: jsonEncode({'error':'Forbidden'}), headers: {'Content-Type':'application/json'});
      
      if (contribCollection == null) {
        return Response(503, body: jsonEncode({'error': 'MongoDB connection unavailable'}), headers: {'Content-Type': 'application/json'});
      }

      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final ids = (data['ids'] as List<dynamic>?)?.cast<String>() ?? [];

      if (ids.isEmpty) {
        return Response.badRequest(body: jsonEncode({'error': 'No IDs provided'}));
      }

      int deletedCount = 0;
      for (final id in ids) {
        try {
          final docId = ObjectId.parse(id);
          await contribCollection?.deleteOne({'_id': docId});
          deletedCount++;
        } catch (e) {
          print('❌ [ADMIN] Error deleting $id: $e');
        }
      }

      print('✅ [ADMIN] Deleted $deletedCount contributions');
      return Response.ok(
        jsonEncode({'success': true, 'deletedCount': deletedCount}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [ADMIN] Error in bulk delete: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Failed to delete contributions: $e'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // ADMIN ROUTES END  // Get contributions by category (public - only approved)
  router.get('/api/contributions/<category>', (Request request, String category) async {
    if (contribCollection == null) {
      return Response.ok(
        jsonEncode([]),
        headers: {'Content-Type': 'application/json'},
      );
    }
    // Only return approved contributions to public
    final filtered = await contribCollection?.find({'category': category, 'status': 'approved'}).toList() ?? [];
    
    // Remove authorEmail from response to protect user privacy
    final sanitized = filtered.map((contrib) {
      contrib.remove('authorEmail');
      return contrib;
    }).toList();
    
    return Response.ok(
      jsonEncode(sanitized),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Get pending contributions (admin only)
  router.get('/api/contributions/pending', (Request request) async {
    try {
      // Extract and verify authorization token
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        print('❌ [PENDING] Missing or invalid authorization header');
        return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: {'Content-Type': 'application/json'});
      }

      final token = authHeader.substring(7);
      
      // Check if user is admin
      if (!_isAdminToken(token)) {
        print('❌ [PENDING] User is not admin');
        return Response(403, body: jsonEncode({'error': 'Forbidden: Admin access required'}), headers: {'Content-Type': 'application/json'});
      }

      if (contribCollection == null) {
        return Response.ok(
          jsonEncode([]),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Get pending contributions (filter by status: 'pending')
      final pending = await contribCollection?.find({'status': 'pending'}).toList() ?? [];
      print('✅ [PENDING] Retrieved ${pending.length} pending contributions');
      
      return Response.ok(
        jsonEncode(pending),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [PENDING] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Add new contribution (only for logged-in users)
  router.post('/api/contributions', (Request request) async {
    try {
      if (contribCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'MongoDB connection unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response.forbidden(jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      final token = authHeader.substring(7);
      
      final userId = _verifyJWT(token);
      if (userId == null) {
        return Response.unauthorized(jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      final user = await _dbGetUserById(userId);
      if (user == null) {
        return Response.forbidden(jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      }
      final username = user['username'] ?? 'Unknown';
      final email = user['email'] ?? 'unknown@email.com';
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;
      data['serverCreatedAt'] = DateTime.now().toIso8601String();
      data['authorId'] = userId;
      // Override with the authenticated user's current username and email
      data['authorName'] = username;
      data['authorUsername'] = username;
      data['authorEmail'] = email;
      // Set status to pending - content must be approved by admin before showing in community
      data['status'] = 'pending';
      final result = await contribCollection?.insertOne(data);
      return Response.ok(
        jsonEncode({'success': result?.isSuccess ?? false, 'id': result?.id?.toHexString()}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to add contribution: $e'}),
      );
    }
  });

  // Update contribution (only owner can edit)
  router.put('/api/contributions/<id>', (Request request, String id) async {
    try {
      if (contribCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'MongoDB connection unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      print('🔵 PUT /api/contributions/$id received');
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        print('❌ Auth header missing or invalid');
        return Response.forbidden(jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      final token = authHeader.substring(7);
      
      final userId = _verifyJWT(token);
      if (userId == null) {
        print('❌ JWT verification failed');
        return Response.unauthorized(jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      print('✅ User authenticated: $userId');
      
      // Parse the ObjectId
      ObjectId docId;
      try {
        docId = ObjectId.parse(id);
        print('✅ ObjectId parsed: $id');
      } catch (e) {
        print('❌ Failed to parse ObjectId: $id - $e');
        return Response.badRequest(body: jsonEncode({'error': 'Invalid document ID format: $e'}));
      }
      
      final doc = await contribCollection?.findOne({'_id': docId});
      if (doc == null) {
        print('❌ Document not found: $id');
        return Response.notFound(
          jsonEncode({'error': 'Contribution not found'}),
        );
      }
      print('✅ Document found');
      
      // Check if content is approved
      final status = doc['status'] as String?;
      final isAdmin = _isAdminToken(token);
      
      // If content is approved, only admin can edit
      if (status == 'approved' && !isAdmin) {
        print('❌ Cannot edit approved content. Only admin can edit approved contributions.');
        return Response.forbidden(
          jsonEncode({
            'error': 'Approved content cannot be edited by users',
            'message': 'Once content is approved, only administrators can make changes. Contact admin if you need to update this contribution.'
          }), 
          headers: {'Content-Type': 'application/json'}
        );
      }
      
      // For pending content, check if user is the author
      if (!isAdmin && doc['authorId'] != userId) {
        print('❌ User is not the author. Doc author: ${doc['authorId']}, User: $userId');
        return Response.forbidden(jsonEncode({'error': 'You can only edit your own contributions'}), headers: {'Content-Type': 'application/json'});
      }
      
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;
      print('✅ Payload decoded, updating document...');
      
      // Preserve serverCreatedAt, authorId, authorUsername, authorName, and status
      data['serverCreatedAt'] = doc['serverCreatedAt'];
      data['authorId'] = doc['authorId'];
      data['authorUsername'] = doc['authorUsername'];
      data['authorName'] = doc['authorName'];
      data['status'] = doc['status']; // Preserve approval status
      data['updatedAt'] = DateTime.now().toIso8601String();
      
      await contribCollection?.updateOne({'_id': docId}, {'\$set': data});
      print('✅ Document updated successfully');
      
      return Response.ok(
        jsonEncode({'success': true}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ Update error: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update contribution: $e'}),
      );
    }
  });

  // Delete contribution (only owner can delete)
  router.delete('/api/contributions/<id>', (Request request, String id) async {
    try {
      if (contribCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'MongoDB connection unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      print('🔵 DELETE /api/contributions/$id received');
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        print('❌ Auth header missing or invalid');
        return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: {'Content-Type': 'application/json'});
      }
      final token = authHeader.substring(7);
      
      // Verify JWT token
      final userId = _verifyJWT(token);
      if (userId == null) {
        print('❌ JWT verification failed');
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: {'Content-Type': 'application/json'});
      }
      print('✅ User authenticated: $userId');
      
      // Parse the ObjectId
      ObjectId docId;
      try {
        docId = ObjectId.parse(id);
        print('✅ ObjectId parsed: $id');
      } catch (e) {
        print('❌ Failed to parse ObjectId: $id - $e');
        return Response.badRequest(body: jsonEncode({'error': 'Invalid document ID format: $e'}));
      }
      
      final doc = await contribCollection?.findOne({'_id': docId});
      if (doc == null) {
        print('❌ Document not found: $id');
        return Response.notFound(
          jsonEncode({'error': 'Contribution not found'}),
        );
      }
      print('✅ Document found');
      
      // Check if content is approved
      final status = doc['status'] as String?;
      final isAdmin = _isAdminToken(token);
      
      // If content is approved, only admin can delete
      if (status == 'approved' && !isAdmin) {
        print('❌ Cannot delete approved content. Only admin can delete approved contributions.');
        return Response.forbidden(
          jsonEncode({
            'error': 'Approved content cannot be deleted by users',
            'message': 'Once content is approved, only administrators can delete it. Contact admin if you need to remove this contribution.'
          }), 
          headers: {'Content-Type': 'application/json'}
        );
      }
      
      // For pending content or if user is admin, check authorization
      final docAuthorId = doc['authorId'] as String?;
      final docAuthorName = doc['authorName'] as String? ?? doc['authorUsername'] as String?;
      print('   Document authorId: $docAuthorId, authorName: $docAuthorName');
      print('   Current userId: $userId, isAdmin: $isAdmin');
      
      // Admin can delete any contribution
      if (isAdmin) {
        print('✅ Admin authorized to delete any contribution');
        await contribCollection?.deleteOne({'_id': docId});
        print('✅ Document deleted by admin');
        return Response.ok(
          jsonEncode({'success': true, 'message': 'Contribution deleted by administrator'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      
      // Authorization check for non-admin users - try multiple methods
      bool isAuthorized = false;
      
      // Method 1: Direct ID match (for new contributions)
      if (docAuthorId != null && docAuthorId == userId) {
        print('✅ Authorized by direct ID match');
        isAuthorized = true;
      }
      
      // Method 2: Check if old authorId belongs to same person (by email)
      if (!isAuthorized && docAuthorId != null) {
        if (_isSameUser(docAuthorId, userId)) {
          print('✅ Authorized by email match (same user, different UUID)');
          isAuthorized = true;
        }
      }
      
      // Method 3: Username match (for legacy data)
      if (!isAuthorized && docAuthorName != null) {
        try {
          String? currentUsername;
          if (!dbAvailable) {
            currentUsername = usersCache.firstWhere((u) => u['id'] == userId)['username'] as String?;
          } else {
            final rows = db.select('SELECT username FROM users WHERE id = ?', [userId]);
            if (rows.isNotEmpty) currentUsername = rows.first['username'] as String?;
          }
          
          if (currentUsername != null && docAuthorName == currentUsername) {
            print('✅ Authorized by username match');
            isAuthorized = true;
          } else {
            print('❌ Username mismatch: $docAuthorName != $currentUsername');
          }
        } catch (e) {
          print('⚠️ Could not check username: $e');
        }
      }
      
      // If no authorization method worked, deny
      if (!isAuthorized) {
        print('❌ User is not authorized to delete this contribution');
        return Response.forbidden(jsonEncode({'error': 'You can only delete your own contributions'}), headers: {'Content-Type': 'application/json'});
      }
      
      print('✅ Authorization verified, proceeding with deletion...');
      
      await contribCollection?.deleteOne({'_id': docId});
      print('✅ Document deleted successfully');
      
      return Response.ok(
        jsonEncode({'success': true}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ Delete error: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to delete contribution: $e'}),
      );
    }
  });

  // Approve contribution (admin only)
  router.put('/api/contributions/<id>/approve', (Request request, String id) async {
    try {
      if (contribCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'MongoDB connection unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      print('✅ [APPROVE] PUT /api/contributions/$id/approve received');
      
      // Extract and verify authorization token
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        print('❌ [APPROVE] Missing or invalid authorization header');
        return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: {'Content-Type': 'application/json'});
      }

      final token = authHeader.substring(7);
      
      // Verify JWT and check if admin
      final userId = _verifyJWT(token);
      if (userId == null || !_isAdminToken(token)) {
        print('❌ [APPROVE] User is not admin');
        return Response(403, body: jsonEncode({'error': 'Forbidden: Admin access required'}), headers: {'Content-Type': 'application/json'});
      }

      // Parse the ObjectId
      ObjectId docId;
      try {
        docId = ObjectId.parse(id);
      } catch (e) {
        print('❌ [APPROVE] Failed to parse ObjectId: $id - $e');
        return Response.badRequest(body: jsonEncode({'error': 'Invalid document ID format: $e'}));
      }

      final doc = await contribCollection?.findOne({'_id': docId});
      if (doc == null) {
        print('❌ [APPROVE] Document not found: $id');
        return Response.notFound(jsonEncode({'error': 'Contribution not found'}));
      }

      // Update status to 'approved'
      await contribCollection?.updateOne({'_id': docId}, {'\$set': {'status': 'approved'}});
      print('✅ [APPROVE] Contribution $id approved');

      return Response.ok(
        jsonEncode({'success': true, 'status': 'approved'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [APPROVE] Exception: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to approve contribution: $e'}),
      );
    }
  });

  // Reject contribution (admin only)
  router.put('/api/contributions/<id>/reject', (Request request, String id) async {
    try {
      if (contribCollection == null) {
        return Response(503,
          body: jsonEncode({'error': 'MongoDB connection unavailable'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      print('❌ [REJECT] PUT /api/contributions/$id/reject received');
      
      // Extract and verify authorization token
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        print('❌ [REJECT] Missing or invalid authorization header');
        return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: {'Content-Type': 'application/json'});
      }

      final token = authHeader.substring(7);
      
      // Verify JWT and check if admin
      final userId = _verifyJWT(token);
      if (userId == null || !_isAdminToken(token)) {
        print('❌ [REJECT] User is not admin');
        return Response(403, body: jsonEncode({'error': 'Forbidden: Admin access required'}), headers: {'Content-Type': 'application/json'});
      }

      // Parse the ObjectId
      ObjectId docId;
      try {
        docId = ObjectId.parse(id);
      } catch (e) {
        print('❌ [REJECT] Failed to parse ObjectId: $id - $e');
        return Response.badRequest(body: jsonEncode({'error': 'Invalid document ID format: $e'}));
      }

      final doc = await contribCollection?.findOne({'_id': docId});
      if (doc == null) {
        print('❌ [REJECT] Document not found: $id');
        return Response.notFound(jsonEncode({'error': 'Contribution not found'}));
      }

      // Parse request body for rejection reason
      String? rejectionReason;
      try {
        final bodyString = await request.readAsString();
        if (bodyString.isNotEmpty) {
          final bodyData = jsonDecode(bodyString);
          rejectionReason = bodyData['rejectionReason'] as String?;
          print('📝 [REJECT] Rejection reason: ${rejectionReason ?? "No reason provided"}');
        }
      } catch (e) {
        print('⚠️ [REJECT] Failed to parse request body: $e');
        // Continue with rejection even if body parsing fails
      }

      // Update status to 'rejected' and optionally add rejection reason
      final updateData = <String, dynamic>{'status': 'rejected'};
      if (rejectionReason != null && rejectionReason.isNotEmpty) {
        updateData['rejectionReason'] = rejectionReason;
      }
      
      await contribCollection?.updateOne({'_id': docId}, {'\$set': updateData});
      print('✅ [REJECT] Contribution $id rejected${rejectionReason != null ? " with reason" : ""}');

      return Response.ok(
        jsonEncode({'success': true, 'status': 'rejected'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ [REJECT] Exception: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to reject contribution: $e'}),
      );
    }
  });

  // CORS headers for web access - UPDATED for Flutter Web
  final handler = Pipeline()
      .addMiddleware(corsHeaders(headers: {
        'Access-Control-Allow-Origin': '*', // Allow all origins for development
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, PATCH',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization, X-Requested-With',
        'Access-Control-Expose-Headers': 'Content-Length, Content-Type',
        'Access-Control-Max-Age': '86400',
        'Access-Control-Allow-Credentials': 'false', // Changed to false for broader compatibility
      }))
      .addMiddleware(logRequests())
      .addHandler((Request request) async {
        final response = await router(request);
        if (response.statusCode == 404) {
          return Response.notFound(
            jsonEncode({'error': 'Route not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        return response;
      });

  // Initialize DB for users
  _initDb();

  // AI proxy endpoint (Gemini-only). Server must set GEMINI_API_KEY in env or community_server/.env
  // Check in environment, then community_server/.env, then repo root ../.env for convenience
  final geminiKey = Platform.environment['GEMINI_API_KEY'] ??
  _readLocalEnvTop('GEMINI_API_KEY') ??
  _readLocalEnvTop('GEMINI_API_KEY', path: '../.env') ??
  _readLocalEnvTop('GOOGLE_API_KEY') ??
  _readLocalEnvTop('GOOGLE_API_KEY', path: '../.env');

  router.post('/api/ai', (Request request) async {
    try {
      final body = await request.readAsString();
      final Map<String, dynamic> data = body.isEmpty ? {} : jsonDecode(body);
      final model = (data['model'] as String?) ?? 'models/gemini-1';
      final input = (data['input'] as String?) ?? data['message'] as String? ?? '';

      if (input.isEmpty) {
        return Response(400, body: jsonEncode({'error': 'No input provided'}), headers: {'Content-Type': 'application/json'});
      }

      if (geminiKey == null || geminiKey.isEmpty) {
        return Response(502, body: jsonEncode({'error': 'GEMINI_API_KEY not configured on server'}), headers: {'Content-Type': 'application/json'});
      }

      // Add a small system instruction to keep replies focused on this project's domain.
      final systemPrompt =
          'You are an assistant for the LearnEase project. Answer only about topics relevant to this project (Java, DBMS, quizzes, code examples, contributions, Flutter integration, server API). Be concise and avoid unrelated content.';
      final payload = jsonEncode({
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': '$systemPrompt\n\nUser: $input'},
            ],
          }
        ],
        'generationConfig': {
          'temperature': 0.2,
        }
      });

      // Discover an available model that supports generateContent for this key/project.
      // Cached for the lifetime of the process.
      String? discoveredModel;
      Future<String?> discoverModel() async {
        if (discoveredModel != null && discoveredModel!.isNotEmpty) return discoveredModel;
        try {
          final listUri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$geminiKey');
          final listResp = await http.get(listUri).timeout(const Duration(seconds: 20));
          if (listResp.statusCode < 200 || listResp.statusCode >= 300) return null;
          final decoded = jsonDecode(listResp.body);
          final models = decoded is Map ? decoded['models'] : null;
          if (models is! List) return null;

          String? pick;
          for (final item in models) {
            if (item is! Map) continue;
            final name = item['name']?.toString();
            if (name == null || name.isEmpty) continue;
            final supported = item['supportedGenerationMethods'];
            if (supported is List && supported.any((m) => m.toString() == 'generateContent')) {
              pick = name;
              // Prefer a flash-style model if present
              if (name.contains('flash')) {
                break;
              }
            }
          }
          discoveredModel = pick;
          return pick;
        } catch (_) {
          return null;
        }
      }

      // Helper to call Gemini for a given model string
      Future<http.Response> callGemini(String m) async {
        final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/$m:generateContent?key=$geminiKey');
        return await http.post(uri, headers: {'Content-Type': 'application/json'}, body: payload).timeout(const Duration(seconds: 30));
      }

      // Try the requested model first, then fallback to a short list of known models if we get NOT_FOUND.
  final envDefault = _readLocalEnvTop('AI_MODEL') ?? _readLocalEnvTop('AI_MODEL', path: '../.env');
  final List<String> tryModels = [
            model,
            envDefault,
            // Common modern Gemini model names
            'models/gemini-1.5-flash',
            'models/gemini-1.5-pro',
            'models/gemini-1.0-pro',
          ]
          .where((s) => s != null && s.trim().isNotEmpty)
          .map((s) => s!.trim())
          .toList();

      http.Response? resp;
      for (final tryModel in tryModels) {
        try {
          resp = await callGemini(tryModel);
        } catch (e) {
          // network/timeout — continue to next
          resp = null;
        }
        if (resp == null) continue;
        if (resp.statusCode == 200) break; // success
        // If the model was not found, try next; for other errors, stop and surface it
        if (resp.statusCode == 404) {
          // try next model
          continue;
        } else {
          // some other error — stop trying
          break;
        }
      }

      // If we got NOT_FOUND for all common models, try auto-discovery via ListModels.
      if (resp != null && resp.statusCode == 404) {
        final auto = await discoverModel();
        if (auto != null && auto.isNotEmpty) {
          try {
            resp = await callGemini(auto);
          } catch (_) {
            // ignore; will fall back below
          }
        }
      }

      if (resp == null) {
        // Gemini network/timeout — fall back to local responder
        final local = _localAnswer(input);
        return Response.ok(jsonEncode({'reply': local, 'provider': 'local', 'raw': {'error': 'Gemini network/timeout'}}), headers: {'Content-Type': 'application/json'});
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // Gemini failed — try Hugging Face inference as a fallback, otherwise return local responder
        try {
          final hfModel = Platform.environment['HF_MODEL'] ?? _readLocalEnvTop('HF_MODEL') ?? _readLocalEnvTop('HF_MODEL', path: '../.env') ?? 'google/flan-t5-small';
          final hfKey = Platform.environment['HF_API_KEY'] ?? _readLocalEnvTop('HF_API_KEY') ?? _readLocalEnvTop('HF_API_KEY', path: '../.env');
          final hfUri = Uri.parse('https://api-inference.huggingface.co/models/$hfModel');
          final hfHeaders = <String, String>{'Content-Type': 'application/json'};
          if (hfKey != null && hfKey.isNotEmpty) hfHeaders['Authorization'] = 'Bearer $hfKey';
          final hfBody = jsonEncode({'inputs': input, 'options': {'wait_for_model': true}});
          final hfResp = await http.post(hfUri, headers: hfHeaders, body: hfBody).timeout(const Duration(seconds: 30));
          if (hfResp.statusCode >= 200 && hfResp.statusCode < 300) {
            dynamic hfDecoded;
            try {
              hfDecoded = jsonDecode(hfResp.body);
            } catch (_) {
              hfDecoded = hfResp.body;
            }
            String hfReply = '';
            if (hfDecoded is List && hfDecoded.isNotEmpty) {
              final first = hfDecoded[0];
              if (first is Map && first['generated_text'] != null) hfReply = first['generated_text'].toString();
            }
            if (hfReply.isEmpty && hfDecoded is Map && hfDecoded['generated_text'] != null) hfReply = hfDecoded['generated_text'].toString();
            if (hfReply.isEmpty && hfDecoded is String) hfReply = hfDecoded;
            if (hfReply.isEmpty) hfReply = hfResp.body;
            return Response.ok(jsonEncode({'reply': hfReply, 'provider': 'huggingface', 'raw': hfDecoded}), headers: {'Content-Type': 'application/json'});
          }
        } catch (e) {
          // ignore
        }

        // Both Gemini and HF failed — return local responder output along with provider error
        final local = _localAnswer(input);
        return Response.ok(jsonEncode({'reply': local, 'provider': 'local', 'raw': {'gemini_status': resp.statusCode, 'gemini_body': resp.body}}), headers: {'Content-Type': 'application/json'});
      }

      final decoded = jsonDecode(resp.body);
      String reply = '';
      if (decoded is Map) {
        // v1beta generateContent
        if (decoded['candidates'] is List && decoded['candidates'].isNotEmpty) {
          final cand = decoded['candidates'][0];
          final content = cand is Map ? cand['content'] : null;
          final parts = content is Map ? content['parts'] : null;
          if (parts is List && parts.isNotEmpty) {
            final first = parts[0];
            if (first is Map && first['text'] != null) {
              reply = first['text'].toString();
            }
          }
        }
        // older schema fallback
        if (reply.isEmpty && decoded['output'] is Map && decoded['output']['text'] != null) {
          reply = decoded['output']['text'].toString();
        }
      }
      if (reply.isEmpty) reply = resp.body;
      return Response.ok(jsonEncode({'reply': reply, 'provider': 'gemini', 'raw': decoded}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Send password reset OTP to email
  router.post('/api/auth/send-reset-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final logMsg = '[RESET OTP] Received send-reset-otp request: ' + body;
      print(logMsg);
      File('reset_otp_debug.log').writeAsStringSync('$logMsg\n', mode: FileMode.append);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      if (email == null || !email.contains('@')) return Response(400, body: jsonEncode({'error': 'Invalid email'}), headers: {'Content-Type': 'application/json'});
      
      final user = await _dbGetUserByEmail(email);
      if (user == null) {
        // Return clear error for password reset when email not found
        File('reset_otp_debug.log').writeAsStringSync('[RESET OTP] Email not registered: $email\n', mode: FileMode.append);
        return Response(404, body: jsonEncode({'sent': false, 'error': 'No account found with this email address. Please check your email or create a new account.'}), headers: {'Content-Type': 'application/json'});
      }
      
      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
      final expires = DateTime.now().add(const Duration(minutes: 5));
      _dbSaveEmailOtp(email, code, expires.toIso8601String(), 0);
      File('reset_otp_debug.log').writeAsStringSync('[RESET OTP] OTP Saved: email=$email, code=$code\n', mode: FileMode.append);
      print('[RESET OTP] Email OTP saved for $email: $code (expires ${expires.toIso8601String()})');
      final subject = 'LearnEase Password Reset OTP';
      final bodyText = 'Your LearnEase password reset OTP is: $code\nValid for 5 minutes.';
      final sent = await _sendEmail(email, subject, bodyText);
      print('[RESET OTP] Email send result: ${sent ? 'SUCCESS' : 'FAILURE'}');
      return Response.ok(jsonEncode({'sent': sent}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('[RESET OTP] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Username uniqueness check endpoint
  router.get('/api/auth/check-username', (Request request) {
    final username = request.url.queryParameters['username']?.trim();
    if (username == null || username.isEmpty) {
      return Response(400, body: jsonEncode({'error': 'Missing username'}), headers: {'Content-Type': 'application/json'});
    }
    // Check in users table (SQLite)
    bool taken = false;
    if (dbAvailable) {
      final rs = db.select('SELECT id FROM users WHERE username = ?;', [username]);
      taken = rs.isNotEmpty;
    } else {
      taken = usersCache.any((u) => u['username'] == username);
    }
    return Response.ok(jsonEncode({'taken': taken}), headers: {'Content-Type': 'application/json'});
  });

  // Email uniqueness check endpoint
  router.get('/api/auth/check-email', (Request request) async {
    final email = request.url.queryParameters['email']?.trim().toLowerCase();
    if (email == null || email.isEmpty) {
      return Response(400, body: jsonEncode({'error': 'Missing email'}), headers: {'Content-Type': 'application/json'});
    }
    // Check in users table (MongoDB first, then SQLite)
    final user = await _dbGetUserByEmail(email);
    return Response.ok(jsonEncode({'taken': user != null}), headers: {'Content-Type': 'application/json'});
  });

  // Send OTP for account deletion
  router.post('/api/auth/send-delete-account-otp', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();

      if (email == null || !email.contains('@')) {
        return Response(400, body: jsonEncode({'error': 'Invalid email'}), headers: {'Content-Type': 'application/json'});
      }

      // Verify user exists
      final user = await _dbGetUserByEmail(email);
      if (user == null) {
        print('[DELETE ACCOUNT OTP] ❌ Email not registered: $email');
        return Response(401, body: jsonEncode({'error': 'No account found with this email address.', 'sent': false}), headers: {'Content-Type': 'application/json'});
      }

      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 899999)).toString();
      final expires = DateTime.now().add(const Duration(minutes: 10));
      _dbSaveEmailOtp(email, code, expires.toIso8601String(), 0);
      print('[DELETE ACCOUNT OTP] ✅ OTP saved for $email: $code');

      final subject = 'LearnEase Account Deletion OTP';
      final bodyText = 'Your LearnEase account deletion OTP is: $code\nValid for 10 minutes.\n\n⚠️ WARNING: This action is IRREVERSIBLE. All your data, contributions, and progress will be permanently deleted.';
      final sent = await _sendEmail(email, subject, bodyText);
      print('[DELETE ACCOUNT OTP] Email send result: ${sent ? 'SUCCESS' : 'FAILURE'}');
      return Response.ok(jsonEncode({'sent': sent, 'message': 'OTP sent to your email'}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('[DELETE ACCOUNT OTP] Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Server error'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Delete account with OTP verification
  router.post('/api/auth/delete-account', (Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final email = (data['email'] as String?)?.trim().toLowerCase();
      final code = data['code'] as String?;
      final authHeader = request.headers['authorization'];

      if (email == null || code == null || authHeader == null) {
        return Response(400, body: jsonEncode({'error': 'Missing email, OTP code, or auth token'}), headers: {'Content-Type': 'application/json'});
      }

      // Verify JWT token
      final tokenStr = authHeader.replaceFirst('Bearer ', '');
      String? userId;
      try {
        final jwt = JWT.verify(tokenStr, SecretKey(jwtSecret));
        userId = jwt.payload['sub'] as String?;
      } on JWTExpiredException {
        print('[DELETE ACCOUNT] ❌ JWT expired');
        return Response(401, body: jsonEncode({'error': 'Token expired. Please login again.'}), headers: {'Content-Type': 'application/json'});
      } catch (e) {
        print('[DELETE ACCOUNT] ❌ JWT verification failed: $e');
        return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: {'Content-Type': 'application/json'});
      }

      if (userId == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid token'}), headers: {'Content-Type': 'application/json'});
      }

      // Verify user exists and matches
      final user = await _dbGetUserByEmail(email);
      if (user == null) {
        print('[DELETE ACCOUNT] ❌ User not found: $email');
        return Response(404, body: jsonEncode({'error': 'User not found'}), headers: {'Content-Type': 'application/json'});
      }

      if (user['id'] != userId) {
        print('[DELETE ACCOUNT] ❌ User ID mismatch. JWT user: $userId, Email user: ${user['id']}');
        return Response(403, body: jsonEncode({'error': 'Cannot delete another user\'s account'}), headers: {'Content-Type': 'application/json'});
      }

      // Verify OTP
      final record = _dbGetEmailOtp(email);
      if (record == null) {
        print('[DELETE ACCOUNT] ❌ No OTP found for $email');
        return Response(400, body: jsonEncode({'error': 'No OTP requested. Please request an OTP first.'}), headers: {'Content-Type': 'application/json'});
      }

      if (record['code'] != code) {
        print('[DELETE ACCOUNT] ❌ Invalid OTP for $email');
        return Response(400, body: jsonEncode({'error': 'Invalid OTP code'}), headers: {'Content-Type': 'application/json'});
      }

      final expires = DateTime.parse(record['expiresAt'] as String);
      if (DateTime.now().isAfter(expires)) {
        print('[DELETE ACCOUNT] ❌ OTP expired for $email');
        _dbDeleteEmailOtp(email);
        return Response(400, body: jsonEncode({'error': 'OTP has expired. Please request a new one.'}), headers: {'Content-Type': 'application/json'});
      }

      // All verifications passed - DELETE USER AND THEIR CONTRIBUTIONS
      try {
        // Delete user from SQLite
        final stmt = db.prepare('DELETE FROM users WHERE id = ?;');
        stmt.execute([userId]);
        print('[DELETE ACCOUNT] ✅ User deleted from database: $userId ($email)');

        // KEEP contributions when user deletes account (community content persists)
        // Contributions remain in database for community value
        // Only admin can delete approved contributions
        if (mongoDb != null && contribCollection != null) {
          final userContribs = await contribCollection!.find(where.eq('authorId', userId)).toList();
          print('[DELETE ACCOUNT] ℹ️  User has ${userContribs.length} contributions that will remain in community');
        }

        // Delete OTP record
        _dbDeleteEmailOtp(email);

        // Delete all sessions for this user
        final sessionStmt = db.prepare('DELETE FROM sessions WHERE user_id = ?;');
        sessionStmt.execute([userId]);
        print('[DELETE ACCOUNT] ✅ All sessions deleted for user: $userId');

        return Response.ok(
          jsonEncode({'success': true, 'message': 'Account and all associated data permanently deleted'}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (deleteErr) {
        print('[DELETE ACCOUNT] ❌ Error during deletion: $deleteErr');
        return Response.internalServerError(
          body: jsonEncode({'error': 'Error deleting account: ${deleteErr.toString()}'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    } catch (e) {
      print('[DELETE ACCOUNT] ❌ Exception: $e');
      return Response.internalServerError(body: jsonEncode({'error': 'Server error'}), headers: {'Content-Type': 'application/json'});
    }
  });

  // Start server
  final port = int.tryParse(Platform.environment['PORT'] ?? '8081') ?? 8081;
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('🚀 Community Server running on http://localhost:${server.port}');
}
// ...existing code...
// Send password reset OTP to email
// ...existing code...

// Local responder: simple keyword search over docs and contributions for offline replies
String _localAnswer(String input) {
  try {
    final docs = <String>[];
    // Add project documentation if present
    final docFile = File('../PROJECT_DOCUMENTATION.md');
    if (docFile.existsSync()) {
      docs.add(docFile.readAsStringSync());
    }
    final readme = File('../README.md');
    if (readme.existsSync()) docs.add(readme.readAsStringSync());

    // Add contributions content
    final contribFile = File('contributions.json');
    if (contribFile.existsSync()) {
      try {
        final raw = contribFile.readAsStringSync();
        final List<dynamic> arr = jsonDecode(raw);
        for (final item in arr) {
          try {
            if (item is Map && item['content'] != null) {
              final c = item['content'];
              if (c is Map) {
                if (c['title'] != null) docs.add(c['title'].toString());
                if (c['explanation'] != null) docs.add(c['explanation'].toString());
                if (c['codeSnippet'] != null) docs.add(c['codeSnippet'].toString());
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    final corpus = docs.join('\n');
    if (corpus.trim().isEmpty) return 'Sorry, no local documentation is available to answer that right now.';

    // Simple keyword matching: pick sentences containing any input keywords
    final keywords = input
        .toLowerCase()
        .split(RegExp(r"\W+"))
        .where((s) => s.length > 2)
        .toSet()
        .toList();
    if (keywords.isEmpty) return 'Could you rephrase? I need a few keywords to search the docs.';

    // Break corpus into sentences and score by keyword matches
  final sentences = corpus.split(RegExp(r'(?<=[\.\?\!])\s+')).map((s) => s.trim()).where((s) => s.length>20).toList();
    final scored = <Map<String, dynamic>>[];
    for (final s in sentences) {
      final low = s.toLowerCase();
      var score = 0;
      for (final k in keywords) {
        if (low.contains(k)) score++;
      }
      if (score>0) scored.add({'s': s, 'score': score});
    }
    if (scored.isEmpty) return 'I could not find a direct match in the project docs; try asking about Java, DBMS, contributions, or the server API.';
    scored.sort((a,b)=> (b['score'] as int).compareTo(a['score'] as int));
    // Return top 2 sentences joined
    final top = scored.take(2).map((m) => m['s']).join(' ');
    return top;
  } catch (e) {
    return 'Local responder failed: ${e.toString()}';
  }
}
