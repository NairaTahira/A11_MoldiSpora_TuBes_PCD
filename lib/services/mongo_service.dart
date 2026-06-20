import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mongo_dart/mongo_dart.dart';
import '../models/detection_result.dart';

class MongoService {
  static Db? _db;
  static DbCollection? _collection;
  static bool _isConnected = false;

  static bool get isConnected => _isConnected;

  static Future<void> connect() async {
    try {
      final url = dotenv.env['MONGO_URL'] ?? '';
      final dbName = dotenv.env['MONGO_DB_NAME'] ?? 'detection_results';
      final collectionName = dotenv.env['MONGO_COLLECTION'] ?? 'mold';

      _db = await Db.create(url);
      await _db!.open();
      _collection = _db!.collection(collectionName);
      _isConnected = true;
      debugPrint('✅ MongoDB connected: $dbName/$collectionName');
    } catch (e) {
      _isConnected = false;
      debugPrint('❌ MongoDB connect failed: $e');
    }
  }

  static Future<void> uploadResult(DetectionResult result) async {
    // reconnect if dropped
    if (!_isConnected || _db == null || !_db!.isConnected) {
      await connect();
    }
    if (!_isConnected || _collection == null) return;
    
    try {
      await _collection!.insertOne({
        '_id': result.id,
        'timestamp': result.timestamp.toIso8601String(),
        'label': result.label,
        'confidence': result.confidence,
        'riskLevel': result.riskLevel,
        'location': result.location,
        'imagePath': result.imagePath,
        'synced': true,
      });
      debugPrint('✅ Uploaded to MongoDB: ${result.label}');
    } catch (e) {
      _isConnected = false; // mark as disconnected for retry
      debugPrint('❌ MongoDB upload failed: $e');
      rethrow;
    }
  }

  static Future<void> disconnect() async {
    await _db?.close();
    _isConnected = false;
  }
}