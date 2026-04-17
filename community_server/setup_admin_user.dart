import 'package:sqlite3/sqlite3.dart';
import 'package:bcrypt/bcrypt.dart';
import 'dart:io';

// Helper to read from environment or .env file
String? _getEnv(String key) {
  // First try environment variables
  final envValue = Platform.environment[key];
  if (envValue != null && envValue.isNotEmpty) {
    return envValue;
  }
  
  // Then try .env file
  try {
    final envFile = File('.env');
    if (envFile.existsSync()) {
      final lines = envFile.readAsLinesSync();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final idx = trimmed.indexOf('=');
        if (idx <= 0) continue;
        final k = trimmed.substring(0, idx).trim();
        var v = trimmed.substring(idx + 1).trim();
        if (v.startsWith('"') && v.endsWith('"')) {
          v = v.substring(1, v.length - 1);
        }
        if (k == key) return v;
      }
    }
  } catch (_) {}
  
  return null;
}

void main(List<String> args) {
  print('🔧 Setting up admin user...\n');

  // Read credentials from environment variables or .env file
  // Usage:
    //   dart run setup_admin_user.dart [email] [password]
    //   OR set ADMIN_EMAIL, ADMIN_PASSWORD env vars
    //   OR create .env file with those variables

    final adminEmail = args.isNotEmpty
      ? args[0].toLowerCase()
      : (_getEnv('ADMIN_EMAIL')?.toLowerCase() ?? 'admin@learnease.com').toLowerCase();

    final adminPassword = args.length > 1
      ? args[1]
      : (_getEnv('ADMIN_PASSWORD') ?? 'admin@123');
  
  // Connect to the database
  final db = sqlite3.open('users.db');

  // Create users table if it does not exist
  db.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE,
      password_hash TEXT,
      created_at TEXT,
      username TEXT,
      admin_passkey TEXT
    );
  ''');

  // Hash the password with BCrypt
  final passwordHash = BCrypt.hashpw(adminPassword, BCrypt.gensalt());

  print('✅ Credentials loaded from: ${args.isNotEmpty ? 'command-line arguments' : 'environment variables / .env file'}');
  print('Admin Email: $adminEmail');
  print('Password Hash: ${passwordHash.substring(0, 30)}...');

  // Check if admin already exists
  try {
    final existing = db.select('SELECT id, email FROM users WHERE email = ?', [adminEmail]);
    if (existing.isNotEmpty) {
      print('⚠️  Admin user already exists');
      print('ID: ${existing.first['id']}');
      print('Email: ${existing.first['email']}');
      
      // Update the password and passkey
      print('\n🔄 Updating admin credentials...');
      db.execute('UPDATE users SET password_hash = ? WHERE email = ?', [passwordHash, adminEmail]);
      print('✅ Admin credentials updated!');
    } else {
      throw Exception('Admin user not found');
    }
  } catch (e) {
    print('⚠️  Creating new admin user...');
    try {
      db.execute('''
        INSERT INTO users (id, email, password_hash, created_at, username)
        VALUES (?, ?, ?, ?, ?)
      ''', [
        'admin-user-001',
        adminEmail,
        passwordHash,
        DateTime.now().toIso8601String(),
        'admin',
      ]);
      print('✅ Admin user created successfully!');
    } catch (createError) {
      print('❌ Error creating admin: $createError');
    }
  }
  
  // Verify the user exists and credentials work
  print('\n🔐 Verifying admin credentials...');
  try {
    final user = db.select('SELECT * FROM users WHERE email = ?', [adminEmail]);
    if (user.isNotEmpty) {
      final row = user.first;
      final storedHash = row['password_hash'] as String;
      final storedPasskeyHash = row['admin_passkey'] as String?;
      final isPasswordValid = BCrypt.checkpw(adminPassword, storedHash);
      final isPasskeyValid = storedPasskeyHash != null && BCrypt.checkpw(adminPasskey, storedPasskeyHash);
      
      if (isPasswordValid && isPasskeyValid) {
        print('✅ Admin credentials verified!');
        print('   Email: ${row['email']}');
        print('   ID: ${row['id']}');
        print('   Username: ${row['username']}');
        print('   Has Admin Passkey: true');
      } else {
        print('❌ Credential verification failed');
        print('   Password valid: $isPasswordValid');
        print('   Passkey valid: $isPasskeyValid');
      }
    }
  } catch (e) {
    print('❌ Verification error: $e');
  }
  
  print('\n✅ Setup complete!');
  print('\nTo login as admin:');
  print('  Email: $adminEmail');
  print('  Password: $adminPassword');
  print('  Passkey: $adminPasskey');
}
