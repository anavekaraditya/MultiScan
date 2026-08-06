import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'vision_scanner_service.dart';

class StoredScan {
  const StoredScan({required this.trayNumber, required this.imagePath, required this.cells});
  final int trayNumber;
  final String imagePath;
  final List<VisionCellResult> cells;
}

class StoredScanSummary {
  const StoredScanSummary({required this.trayNumber, required this.createdAt, required this.accepted, required this.total});
  final int trayNumber;
  final DateTime createdAt;
  final int accepted;
  final int total;
}

class ScanStore {
  ScanStore._();
  static final instance = ScanStore._();
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final databasePath = path.join(await getDatabasesPath(), 'multiscan.sqlite');
    _database = await openDatabase(databasePath, version: 1, onCreate: (db, _) async {
      await db.execute('''CREATE TABLE scan_batches(
        id TEXT PRIMARY KEY,
        tray_number INTEGER NOT NULL,
        image_path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        layout_version TEXT NOT NULL,
        processing_version TEXT NOT NULL
      )''');
      await db.execute('''CREATE TABLE scan_cells(
        scan_id TEXT NOT NULL,
        position TEXT NOT NULL,
        imei TEXT,
        status TEXT NOT NULL,
        source TEXT NOT NULL,
        confidence REAL NOT NULL,
        reason TEXT NOT NULL,
        PRIMARY KEY(scan_id, position),
        FOREIGN KEY(scan_id) REFERENCES scan_batches(id) ON DELETE CASCADE
      )''');
    });
    return _database!;
  }

  Future<void> saveScan({required String scanId, required int trayNumber, required VisionScanResult result}) async {
    final db = await database;
    final storedImagePath = await _persistSourceImage(result.imagePath, scanId);
    await db.transaction((txn) async {
      await txn.insert('scan_batches', {
        'id': scanId,
        'tray_number': trayNumber,
        'image_path': storedImagePath,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'layout_version': '3x5-v1',
        'processing_version': result.processingVersion,
      });
      for (final cell in result.cells) {
        await txn.insert('scan_cells', {
          'scan_id': scanId,
          'position': cell.position,
          'imei': cell.imei,
          'status': cell.status.name,
          'source': cell.source,
          'confidence': cell.confidence,
          'reason': cell.reason,
        });
      }
    });
  }

  Future<String> _persistSourceImage(String sourcePath, String scanId) async {
    final directory = await getApplicationDocumentsDirectory();
    final scanDirectory = Directory(path.join(directory.path, 'scan_images'));
    await scanDirectory.create(recursive: true);
    final destination = path.join(scanDirectory.path, '$scanId.jpg');
    try {
      await File(sourcePath).copy(destination);
      return destination;
    } catch (_) {
      return sourcePath;
    }
  }

  Future<StoredScan?> loadLatest() async {
    final db = await database;
    final batches = await db.query('scan_batches', orderBy: 'created_at DESC', limit: 1);
    if (batches.isEmpty) return null;
    final batch = batches.first;
    final rows = await db.query('scan_cells', where: 'scan_id = ?', whereArgs: [batch['id']], orderBy: 'position ASC');
    final cells = rows.map((row) => VisionCellResult(
          position: row['position'] as String,
          imei: row['imei'] as String?,
          status: switch (row['status'] as String) {
            'accepted' => VisionCellStatus.accepted,
            'review' => VisionCellStatus.review,
            _ => VisionCellStatus.retake,
          },
          source: row['source'] as String,
          confidence: (row['confidence'] as num).toDouble(),
          reason: row['reason'] as String,
        )).toList();
    return StoredScan(trayNumber: batch['tray_number'] as int, imagePath: batch['image_path'] as String, cells: cells);
  }

  Future<List<StoredScanSummary>> loadRecent({int limit = 5}) async {
    final db = await database;
    final batches = await db.query('scan_batches', orderBy: 'created_at DESC', limit: limit);
    final summaries = <StoredScanSummary>[];
    for (final batch in batches) {
      final rows = await db.query('scan_cells', columns: ['status'], where: 'scan_id = ?', whereArgs: [batch['id']]);
      summaries.add(StoredScanSummary(
        trayNumber: batch['tray_number'] as int,
        createdAt: DateTime.tryParse(batch['created_at'] as String) ?? DateTime.now(),
        accepted: rows.where((row) => row['status'] == VisionCellStatus.accepted.name).length,
        total: rows.length,
      ));
    }
    return summaries;
  }
}
