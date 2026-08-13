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
    final response = await http.post(
      Uri.parse('$baseUrl/v1/sessions/$sessionCode/batches'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
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
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Dashboard sync failed (${response.statusCode}).');
    }
  }
}
