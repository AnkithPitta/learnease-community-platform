import 'package:mongo_dart/mongo_dart.dart';
import 'package:bcrypt/bcrypt.dart';
import 'dart:io';

void main() async {
  // Read from environment variable (Vardhan's MongoDB Atlas account)
  final mongoUri = Platform.environment['MONGODB_URI'];
  
  if (mongoUri == null) {
    print('❌ ERROR: MONGODB_URI environment variable not set!');
    print('💡 Set it in your environment or .env file');
    print('   This should use Vardhan\'s MongoDB Atlas credentials (rayapureddyvardhan account)');
    exit(1);
  }
  
  print('🔍 Checking Admin User in MongoDB\n');
  
  try {
    print('🔌 Connecting to MongoDB...');
    final db = await Db.create(mongoUri);
    await db.open();
    print('✅ Connected!\n');
    
    final usersCollection = db.collection('users');
    
    // Find admin user
    print('📋 Looking for admin@learnease.com...');
    final admin = await usersCollection.findOne(where.eq('email', 'admin@learnease.com'));
    
    if (admin == null) {
      print('❌ PROBLEM: Admin user does NOT exist in MongoDB!');
      print('\n💡 Solution: You need to CREATE the admin user first.');
      print('   Run: dart run community_server/setup_admin_user.dart');
      await db.close();
      exit(1);
    }
    
    print('✅ Admin user found!\n');
    print('=' * 60);
    print('ADMIN USER DETAILS:');
    print('=' * 60);
    print('ID: ${admin['id']}');
    print('Email: ${admin['email']}');
    print('Username: ${admin['username']}');
    print('');
    
    // Check password_hash
    final passwordHash = admin['password_hash'] as String?;
    if (passwordHash == null) {
      print('❌ password_hash: MISSING (NULL)');
    } else {
      print('✅ password_hash: EXISTS (${passwordHash.length} chars)');
      print('   Hash format: ***hidden***');
      
      // Test password - PROMPT user for security
      stdout.write('\n🧪 Enter password to test (or press Enter to skip): ');
      final testPassword = stdin.readLineSync();
      
      if (testPassword != null && testPassword.isNotEmpty) {
        final matches = BCrypt.checkpw(testPassword, passwordHash);
        if (matches) {
          print('   ✅ Password MATCHES!');
        } else {
          print('   ❌ Password does NOT match');
        }
      } else {
        print('   ⏭️  Skipped password test');
      }
    }
    
    print('');
    
    // Check admin_passkey
    final passkeyHash = admin['admin_passkey'] as String?;
    if (passkeyHash == null) {
      print('❌ admin_passkey: MISSING (NULL)');
    } else {
      print('✅ admin_passkey: EXISTS (${passkeyHash.length} chars)');
      print('   Hash format: ***hidden***');
      
      // Test passkey - PROMPT user for security
      stdout.write('\n🧪 Enter passkey to test (or press Enter to skip): ');
      final testPasskey = stdin.readLineSync();
      
      if (testPasskey != null && testPasskey.isNotEmpty) {
        final matches = BCrypt.checkpw(testPasskey, passkeyHash);
        if (matches) {
          print('   ✅ Passkey MATCHES!');
        } else {
          print('   ❌ Passkey does NOT match');
        }
      } else {
        print('   ⏭️  Skipped passkey test');
      }
    }
    
    print('\n${'=' * 60}');
    print('SUMMARY:');
    print('=' * 60);
    
    if (passwordHash == null) {
      print('❌ Password is NOT SET');
    } else {
      print('✅ Password hash is SET');
    }
    
    if (passkeyHash == null) {
      print('❌ Passkey is NOT SET');
    } else {
      print('✅ Passkey hash is SET');
    }
    
    print('=' * 60);
    
    // Offer to fix if credentials missing
    if (passwordHash == null || passkeyHash == null) {
      print('\n💡 SOLUTION: Set credentials using environment variables');
      print('   Run: dart run community_server/set_admin_passkey.dart');
    }
    
    await db.close();
    print('\n✅ Done!');
  } catch (e, stackTrace) {
    print('❌ Error: $e');
    print('Stack trace: $stackTrace');
    exit(1);
  }
}
