import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/detection_result.dart';
import 'mongo_service.dart';

class HiveService {
  static const _boxName = 'scan_history';

  Box<DetectionResult> get _box => Hive.box<DetectionResult>(_boxName);

  Future<void> syncPendingResults() async {
  if (!MongoService.isConnected) {
    await MongoService.connect();
  }
  final unsynced = _box.values.where((r) => !r.synced).toList();
  for (final result in unsynced) {
    try {
      await MongoService.uploadResult(result);
      result.synced = true;
      await result.save();
      debugPrint('✅ Synced: ${result.label}');
    } catch (_) {
      debugPrint('⚠️ Sync failed for ${result.id}, will retry later');
    }
  }
}

  Future<void> saveResult(DetectionResult result) async {
    await _box.put(result.id, result);
  }

  List<DetectionResult> getAllResults() {
    final results = _box.values.toList();
    results.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return results;
  }

  List<DetectionResult> getRecentResults({int limit = 5}) {
    return getAllResults().take(limit).toList();
  }

  Future<void> deleteResult(String id) async {
    await _box.delete(id);
  }

  Future<void> clearAll() async {
    await _box.clear();
  }

  double getRoomSafetyScore() {
    final results = getAllResults();
    if (results.isEmpty) return 100.0;
    final moldResults = results
        .where((r) =>
            r.label == 'Stachybotrys_Black_Mold' ||
            r.label == 'Aspergillus_Green_Mold' ||
            r.label == 'Cladosporium_White_Brown')
        .toList();
    if (moldResults.isEmpty) return 95.0;
    final avgConf = moldResults.map((r) => r.confidence).reduce((a, b) => a + b) / moldResults.length;
    return ((1.0 - avgConf) * 100).clamp(0.0, 100.0);
  }

  String getRiskLabel(double score) {
    if (score >= 80) return 'Safe from major spores';
    if (score >= 60) return 'Moderately Safe';
    if (score >= 40) return 'Moderate Risk';
    return 'High Risk – Act Now';
  }
}

Future<void> restoreFromCloudIfEmpty() async {
  final box = Hive.box<DetectionResult>(HiveService._boxName);
  if (box.isNotEmpty) {
    debugPrint('ℹ️ Hive box already has data, skip restore.');
    return;
  }

  final remoteResults = await MongoService.fetchAllResults();
  if (remoteResults.isEmpty) {
    debugPrint('ℹ️ No remote data to restore.');
    return;
  }

  for (final doc in remoteResults) {
    try {
      final result = DetectionResult(
        id: doc['_id'] as String,
        timestamp: DateTime.parse(doc['timestamp'] as String),
        confidence: (doc['confidence'] as num).toDouble(),
        label: doc['label'] as String,
        imagePath: doc['imagePath'] as String?,
        location: doc['location'] as String? ?? 'Unknown',
        riskLevel: doc['riskLevel'] as String,
        synced: true, // already came from cloud, no need to re-upload
      );
      await box.put(result.id, result);
    } catch (e) {
      debugPrint('⚠️ Skipped one corrupted remote record: $e');
    }
  }
  debugPrint('✅ Restored ${remoteResults.length} results from cloud to Hive.');
}