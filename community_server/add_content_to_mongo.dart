import 'package:mongo_dart/mongo_dart.dart';
import 'dart:io';
import 'course_content.dart';

void main() async {
  // Step 1: Get MongoDB URI from environment or paste it here
  // Replace <db_password> with your actual password and <your_db_name> with your database name (e.g., LearnEase)
  final mongoUri = "mongodb+srv://ankithpitta2422_db_user:Ankith_2789@learnease.wcfnbzn.mongodb.net/LearnEase?retryWrites=true&w=majority";
  final db = await Db.create(mongoUri);
  await db.open();

  // Step 2: Get collections
  final coursesCollection = db.collection('courses');
  final quizzesCollection = db.collection('quizzes');

  // Step 3: Insert course content
  await coursesCollection.insert(courseContent);

  // Step 4: Insert quiz questions
  for (var question in quizQuestions) {
    await quizzesCollection.insert(question);
  }

  await db.close();
  print('✅ Content added to MongoDB!');
}
