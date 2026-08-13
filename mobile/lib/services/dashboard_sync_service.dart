import 'dart:convert';

import 'package:http/http.dart' as http;

import 'vision_scanner_service.dart';

class DashboardSyncService {
  DashboardSyncService._();
  static final instance = DashboardSyncService._();
  static const hostedBaseUrl = 'https://multi-scan-nine.vercel.app';

  String? _baseUrl;
  String? _sessionCode;

  bool get isConnected => _baseUrl != null && _sessionCode != null;
  String? get sessionCode => _sessionCode;

  Future<void> connect({required String sessionCode}) async {
    const normalizedUrl = hostedBaseUrl;
    final normalizedCode = sessionCode.trim().toUpperCase();
    if (normalizedCode.isEmpty) throw StateError('Enter the session code.');
    final response = await http.get(Uri.parse('$normalizedUrl/v1/sessions/$normalizedCode'));
    if (response.statusCode != 200) throw StateError('Session not found on the dashboard.');
    _baseUrl = normalizedUrl;
    _sessionCode = normalizedCode;
  }

  Future<void> syncScan({required String batchId, required int trayNumber, required VisionScanResult result}) async {
    final baseUrl = _baseUrl;
    final sessionCode = _sessionCode;
    if (baseUrl == null || sessionCode == null) throw StateError('Connect to the laptop dashboard first.');
    final requestBody = jsonEncode({
        'batch_id': batchId,
        'tray_number': trayNumber,
        'cells': result.cells.map((cell) => {
              'position': cell.position,
              'imei': cell.imei,
              'status': cell.status.name,
              'source': cell.source,
              'confidence': cell.confidence,
              'reason': cell.reason,
            }).toList(),
      });
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        final response = await http.post(Uri.parse('$baseUrl/v1/sessions/$sessionCode/batches'), headers: const {'Content-Type': 'application/json'}, body: requestBody).timeout(const Duration(seconds: 12));
        if (response.statusCode >= 200 && response.statusCode < 300) return;
        lastError = 'HTTP ${response.statusCode}';
      } catch (error) {
        lastError = error;
      }
      if (attempt < 2) await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
    }
    throw StateError('Dashboard sync failed after 3 attempts: $lastError');
  }
}
