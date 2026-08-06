import 'package:flutter/services.dart';

enum VisionCellStatus { accepted, review, retake }

class VisionCellResult {
  const VisionCellResult({required this.position, required this.status, required this.reason, required this.source, required this.confidence, this.imei});

  final String position;
  final String? imei;
  final VisionCellStatus status;
  final String source;
  final double confidence;
  final String reason;

  factory VisionCellResult.fromMap(Map<Object?, Object?> map) => VisionCellResult(
        position: map['position'] as String,
        imei: map['imei'] as String?,
        status: switch (map['status'] as String) {
          'accepted' => VisionCellStatus.accepted,
          'review' => VisionCellStatus.review,
          _ => VisionCellStatus.retake,
        },
        source: map['source'] as String? ?? 'none',
        confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
        reason: map['reason'] as String? ?? 'No readable IMEI',
      );
}

class VisionScanResult {
  const VisionScanResult({required this.imagePath, required this.cells, required this.rawText, required this.processingVersion, this.barcodeValues = const []});

  final String imagePath;
  final List<VisionCellResult> cells;
  final String rawText;
  final String processingVersion;
  final List<String> barcodeValues;
}

class VisionScannerService {
  VisionScannerService._();
  static final instance = VisionScannerService._();
  static const _channel = MethodChannel('multiscan/vision_scanner');

  Future<VisionScanResult> analyzeTray(String imagePath) async {
    final response = await _channel.invokeMethod<Map<Object?, Object?>>('analyzeTray', {'path': imagePath});
    if (response == null) throw StateError('Vision returned no scan result.');
    final rawCells = (response['cells'] as List<Object?>? ?? const <Object?>[]).whereType<Map<Object?, Object?>>();
    final cells = rawCells.map(VisionCellResult.fromMap).toList();
    if (cells.isEmpty) throw StateError('Vision returned no scan positions.');
    final barcodeValues = (response['barcodeValues'] as List<Object?>? ?? const <Object?>[]).whereType<String>().toList(growable: false);
    return VisionScanResult(
      imagePath: imagePath,
      cells: cells,
      rawText: response['rawText'] as String? ?? '',
      processingVersion: response['processingVersion'] as String? ?? 'ios-vision-v1',
      barcodeValues: barcodeValues,
    );
  }
}
