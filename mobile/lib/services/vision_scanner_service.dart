import 'package:flutter/services.dart';

enum VisionCellStatus { accepted, review, retake }

class VisionBox {
  const VisionBox({required this.x, required this.y, required this.width, required this.height});
  final double x;
  final double y;
  final double width;
  final double height;

  factory VisionBox.fromMap(Map<Object?, Object?> map) => VisionBox(
        x: (map['x'] as num?)?.toDouble() ?? 0,
        y: (map['y'] as num?)?.toDouble() ?? 0,
        width: (map['width'] as num?)?.toDouble() ?? 0,
        height: (map['height'] as num?)?.toDouble() ?? 0,
      );
}

class VisionCellResult {
  const VisionCellResult({required this.position, required this.status, required this.reason, required this.source, required this.confidence, this.imei, this.boxes = const []});

  final String position;
  final String? imei;
  final VisionCellStatus status;
  final String source;
  final double confidence;
  final String reason;
  final List<VisionBox> boxes;

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
        boxes: (map['boxes'] as List<Object?>? ?? const <Object?>[]).whereType<Map<Object?, Object?>>().map(VisionBox.fromMap).toList(growable: false),
      );
}

class VisionScanResult {
  const VisionScanResult({required this.imagePath, required this.cells, required this.rawText, required this.processingVersion, this.barcodeValues = const [], this.rawBarcodeCount = 0, this.uniqueBarcodeCount = 0, this.groupCount = 0});

  final String imagePath;
  final List<VisionCellResult> cells;
  final String rawText;
  final String processingVersion;
  final List<String> barcodeValues;
  final int rawBarcodeCount;
  final int uniqueBarcodeCount;
  final int groupCount;
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
      rawBarcodeCount: (response['rawBarcodeCount'] as num?)?.toInt() ?? barcodeValues.length,
      uniqueBarcodeCount: (response['uniqueBarcodeCount'] as num?)?.toInt() ?? barcodeValues.length,
      groupCount: (response['groupCount'] as num?)?.toInt() ?? cells.length,
    );
  }
}
