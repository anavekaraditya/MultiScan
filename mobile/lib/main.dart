import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'services/scan_store.dart';
import 'services/vision_scanner_service.dart';

void main() => runApp(const MultiScanApp());

enum CellStatus { accepted, retake, review }

enum SessionState { idle, active }

class DemoCell {
  const DemoCell(this.position, this.status, this.imei, this.reason, {this.source = 'none', this.confidence = 0});
  final String position;
  final CellStatus status;
  final String? imei;
  final String reason;
  final String source;
  final double confidence;
}

List<DemoCell> buildDemoCells() => List.generate(15, (index) {
      final row = index ~/ 3 + 1;
      final column = index % 3 + 1;
      final position = 'R${row}C$column';
      if (index == 7) return DemoCell(position, CellStatus.retake, null, 'No readable IMEI');
      if (index == 12) return DemoCell(position, CellStatus.review, null, 'Demo review required');
      return DemoCell(position, CellStatus.accepted, '490154203237518', 'Demo result');
    });

class MultiScanApp extends StatelessWidget {
  const MultiScanApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(title: 'MultiScan', debugShowCheckedModeBanner: false, theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2d679d)), useMaterial3: true, scaffoldBackgroundColor: Colors.white), home: const _SplashGate());
}

class _SplashGate extends StatefulWidget {
  const _SplashGate();
  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 650), () { if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AppShell())); });
  }
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Container(width: 150, height: 165, decoration: BoxDecoration(color: const Color(0xffe4e4e4), borderRadius: BorderRadius.circular(28)), child: const Icon(Icons.qr_code_scanner, size: 92, color: Colors.black)), const SizedBox(height: 18), const Text('MultiScan', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))])));
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  SessionState sessionState = SessionState.idle;
  bool sheetLinked = false;
  bool connectingSheet = false;
  String? linkedSheetName;
  int currentSessionDevices = 0;
  int totalDevicesScanned = 10000;
  int activeTrayNumber = 3;
  List<DemoCell> cells = buildDemoCells();
  List<StoredScanSummary> recentScans = const [];

  @override
  void initState() {
    super.initState();
    _restoreLatestScan();
  }

  Future<void> _restoreLatestScan() async {
    try {
      final stored = await ScanStore.instance.loadLatest();
      final recent = await ScanStore.instance.loadRecent();
      if (mounted) setState(() => recentScans = recent);
      if (!mounted || stored == null || stored.cells.isEmpty) return;
      setState(() {
        activeTrayNumber = stored.trayNumber;
        cells = stored.cells.map(_toDemoCell).toList();
        currentSessionDevices = cells.where((cell) => cell.status == CellStatus.accepted).length;
      });
    } catch (_) {
      // A missing or newly upgraded local database must not block the UI.
    }
  }

  void startSession() => setState(() { sessionState = SessionState.active; currentSessionDevices = 0; });
  void endSession() => setState(() { sessionState = SessionState.idle; currentSessionDevices = 0; });
  void openCapture({bool replaceCurrent = false, bool nextTray = false}) {
    if (sessionState != SessionState.active) return;
    final scanTrayNumber = activeTrayNumber + (nextTray ? 1 : 0);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CapturePage(onProcessed: (result) => openReview(result, trayNumber: scanTrayNumber, replaceCurrent: replaceCurrent))));
  }
  void openReview(VisionScanResult result, {required int trayNumber, required bool replaceCurrent}) {
    final scannedCells = result.cells.map(_toDemoCell).toList();
    final scanId = DateTime.now().microsecondsSinceEpoch.toString();
    unawaited(ScanStore.instance.saveScan(scanId: scanId, trayNumber: trayNumber, result: result));
    unawaited(_refreshRecentScans());
    setState(() { cells = scannedCells; activeTrayNumber = trayNumber; currentSessionDevices += scannedCells.where((cell) => cell.status == CellStatus.accepted).length; });
    final navigator = Navigator.of(context);
    if (replaceCurrent) navigator.pop();
    navigator.push(MaterialPageRoute(builder: (_) => ReviewPage(trayNumber: trayNumber, cells: cells, onCellsChanged: (value) => setState(() => cells = value), onRescan: () => openCapture(replaceCurrent: true), onNextTray: () => openCapture(nextTray: true))));
  }

  DemoCell _toDemoCell(VisionCellResult cell) => DemoCell(cell.position, switch (cell.status) {
        VisionCellStatus.accepted => CellStatus.accepted,
        VisionCellStatus.review => CellStatus.review,
        VisionCellStatus.retake => CellStatus.retake,
      }, cell.imei, cell.reason, source: cell.source, confidence: cell.confidence);

  Future<void> _refreshRecentScans() async {
    final recent = await ScanStore.instance.loadRecent();
    if (mounted) setState(() => recentScans = recent);
  }
  void connectSheet() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google Sheets connection will be available in a future update.')));
  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: HomePage(sessionState: sessionState, sheetLinked: sheetLinked, linkedSheetName: linkedSheetName, connectingSheet: connectingSheet, currentSessionDevices: currentSessionDevices, totalDevicesScanned: totalDevicesScanned, recentScans: recentScans, onConnectSheet: connectSheet, onStartSession: startSession, onScan: openCapture, onEndSession: endSession)));
}

class HomePage extends StatelessWidget {
  const HomePage({required this.sessionState, required this.sheetLinked, required this.linkedSheetName, required this.connectingSheet, required this.currentSessionDevices, required this.totalDevicesScanned, required this.recentScans, required this.onConnectSheet, required this.onStartSession, required this.onScan, required this.onEndSession, super.key});
  final SessionState sessionState;
  final bool sheetLinked;
  final String? linkedSheetName;
  final bool connectingSheet;
  final int currentSessionDevices;
  final int totalDevicesScanned;
  final List<StoredScanSummary> recentScans;
  final VoidCallback onConnectSheet;
  final VoidCallback onStartSession;
  final VoidCallback onScan;
  final VoidCallback onEndSession;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 20),
              children: [
                Container(
                  height: 300,
                  padding: const EdgeInsets.fromLTRB(34, 34, 34, 0),
                  decoration: const BoxDecoration(color: Color(0xffe3f1f6), borderRadius: BorderRadius.vertical(bottom: Radius.circular(44))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Hi Deepali,', style: TextStyle(fontSize: 17, color: Colors.black54)),
                    const SizedBox(height: 6),
                    Text(sessionState == SessionState.active ? 'Session in progress' : 'Ready to scan?', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Center(child: Column(children: [
                      const Text('Devices Scanned', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('$currentSessionDevices', style: const TextStyle(fontSize: 58, fontWeight: FontWeight.w500)),
                    ])),
                    const SizedBox(height: 14),
                  ]),
                ),
                Transform.translate(offset: const Offset(0, -22), child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9), decoration: BoxDecoration(color: const Color(0xff326ca5), borderRadius: BorderRadius.circular(20)), child: const Text('Current Session', style: TextStyle(color: Colors.white, fontSize: 12))))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: _LargeAction(label: 'Start', icon: Icons.add, color: const Color(0xff80c900), enabled: sessionState == SessionState.idle, onPressed: onStartSession)),
                      const SizedBox(width: 14),
                      _ScanAction(enabled: sessionState == SessionState.active, onPressed: onScan),
                      const SizedBox(width: 14),
                      Expanded(child: _LargeAction(label: 'End', icon: Icons.close, color: const Color(0xffef5a60), enabled: sessionState == SessionState.active, onPressed: onEndSession)),
                    ]),
                    const SizedBox(height: 28),
                    Row(children: [
                      Expanded(child: _InfoCard(title: 'Local Storage', child: Row(children: [const Icon(Icons.storage_outlined, color: Color(0xff23739a), size: 25), const SizedBox(width: 10), const Expanded(child: Text('Saved on this iPhone\nSQLite enabled', style: TextStyle(fontSize: 14, height: 1.15)))]))),
                      const SizedBox(width: 18),
                      Expanded(
                        child: _InfoCard(
                          title: 'Total Devices Scanned',
                          child: Text(
                            '$totalDevicesScanned',
                            style: const TextStyle(fontSize: 32, color: Color(0xff23739a)),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 28),
                    const Row(children: [Text('Recent Activity', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)), Spacer(), Icon(Icons.chevron_right)]),
                    const SizedBox(height: 12),
                    if (recentScans.isEmpty)
                      const _ActivityRow(date: '—', session: 'No scans yet', devices: '0 devices')
                    else
                      ...recentScans.map((scan) => _ActivityRow(date: _shortDate(scan.createdAt), session: 'Tray ${scan.trayNumber}', devices: '${scan.accepted}/${scan.total} devices')),
                  ]),
                ),
              ],
            ),
          ),
        ],
      );
}

String _shortDate(DateTime date) => '${date.day} ${_monthName(date.month)}';
String _monthName(int month) => const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][month - 1];

class _LargeAction extends StatelessWidget { const _LargeAction({required this.label, required this.icon, required this.color, required this.enabled, required this.onPressed}); final String label; final IconData icon; final Color color; final bool enabled; final VoidCallback onPressed; @override Widget build(BuildContext context) => SizedBox(height: 72, child: FilledButton(onPressed: enabled ? onPressed : null, style: FilledButton.styleFrom(backgroundColor: color, disabledBackgroundColor: const Color(0xffeeeeee), foregroundColor: Colors.white, disabledForegroundColor: Colors.black26, minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13))), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))), const SizedBox(width: 8), Icon(icon, size: 24)]))); }
class _ScanAction extends StatelessWidget { const _ScanAction({required this.enabled, required this.onPressed}); final bool enabled; final VoidCallback onPressed; @override Widget build(BuildContext context) => SizedBox(width: 72, height: 72, child: FilledButton(onPressed: enabled ? onPressed : null, style: FilledButton.styleFrom(backgroundColor: const Color(0xffeeeeee), disabledBackgroundColor: const Color(0xfff5f5f5), foregroundColor: Colors.black, disabledForegroundColor: Colors.black26, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)), padding: EdgeInsets.zero), child: const Icon(Icons.qr_code_scanner, size: 38))); }
class _InfoCard extends StatelessWidget { const _InfoCard({required this.title, required this.child}); final String title; final Widget child; @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)), const SizedBox(height: 10), Container(width: double.infinity, height: 76, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: const Color(0xffe7f3f6), borderRadius: BorderRadius.circular(8)), child: child)]); }
class _ActivityRow extends StatelessWidget { const _ActivityRow({required this.date, required this.session, required this.devices}); final String date; final String session; final String devices; @override Widget build(BuildContext context) => Container(margin: const EdgeInsets.only(bottom: 7), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), decoration: BoxDecoration(color: const Color(0xfffbfbfb), borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Color(0x0c000000), blurRadius: 4, offset: Offset(0, 2))]), child: Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), decoration: BoxDecoration(color: const Color(0xffe2f0f5), borderRadius: BorderRadius.circular(9)), child: Text(date, style: const TextStyle(color: Color(0xff27759c), fontSize: 13))), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(session, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const Text('12:25 PM', style: TextStyle(fontSize: 11))])), Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(devices, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))))])); }
class _BottomActions extends StatelessWidget {
  const _BottomActions({required this.sessionState, required this.onStart, required this.onScan, required this.onEnd});
  final SessionState sessionState;
  final VoidCallback onStart;
  final VoidCallback onScan;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        child: Row(
          children: [
            Expanded(child: _LargeAction(label: 'Start', icon: Icons.add, color: const Color(0xff80c900), enabled: sessionState == SessionState.idle, onPressed: onStart)),
            const SizedBox(width: 12),
            _ScanAction(enabled: sessionState == SessionState.active, onPressed: onScan),
            const SizedBox(width: 12),
            Expanded(child: _LargeAction(label: 'End', icon: Icons.close, color: const Color(0xffef5a60), enabled: sessionState == SessionState.active, onPressed: onEnd)),
          ],
        ),
      );
}

class _WireMetric extends StatelessWidget {
  const _WireMetric({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(children: [Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 28), decoration: BoxDecoration(color: const Color(0xffdedede), borderRadius: BorderRadius.circular(8)), child: Text(value, textAlign: TextAlign.center, style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w600))), const SizedBox(height: 8), Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14))]);
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.date, required this.devices});
  final String date;
  final String devices;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 20), child: Row(children: [Expanded(child: Text(date, style: const TextStyle(fontSize: 14))), Text(devices, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))]));
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.sessionState, required this.onStartSession, required this.onScan, required this.onEndSession});
  final SessionState sessionState;
  final VoidCallback onStartSession;
  final VoidCallback onScan;
  final VoidCallback onEndSession;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(22, 10, 22, 18), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        _ActionButton(icon: Icons.add_box_outlined, label: 'New\nSession', enabled: sessionState == SessionState.idle, onPressed: onStartSession),
        _ActionButton(icon: Icons.qr_code_scanner, label: 'Scan', enabled: sessionState == SessionState.active, onPressed: onScan, emphasized: true),
        _ActionButton(icon: Icons.close, label: 'End\nSession', enabled: sessionState == SessionState.active, onPressed: onEndSession),
      ]));
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.enabled, required this.onPressed, this.emphasized = false});
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final bool emphasized;
  @override
  Widget build(BuildContext context) => SizedBox(width: 106, height: 84, child: FilledButton.tonal(onPressed: enabled ? onPressed : null, style: FilledButton.styleFrom(backgroundColor: emphasized && enabled ? Colors.black : const Color(0xffeeeeee), foregroundColor: emphasized && enabled ? Colors.white : Colors.black, disabledBackgroundColor: const Color(0xfff5f5f5), disabledForegroundColor: const Color(0xffb5b5b5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(vertical: 10)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 25), const SizedBox(height: 4), Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.05, fontWeight: FontWeight.w600))])));
}

class CapturePage extends StatefulWidget {
  const CapturePage({required this.onProcessed, super.key});
  final ValueChanged<VisionScanResult> onProcessed;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  CameraController? controller;
  final ImagePicker picker = ImagePicker();
  Future<void>? cameraInitialization;
  String? cameraError;
  bool processing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cameraInitialization = initializeCamera();
  }

  Future<void> initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('NoCamera', 'No camera is available on this device.');
      final backCamera = cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final nextController = CameraController(backCamera, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await nextController.initialize();
      if (!mounted) {
        await nextController.dispose();
        return;
      }
      controller = nextController;
      setState(() {});
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() => cameraError = error.description ?? error.code);
    } catch (error) {
      if (!mounted) return;
      setState(() => cameraError = error.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final activeController = controller;
    if (activeController == null || !activeController.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      activeController.dispose();
      controller = null;
    } else if (state == AppLifecycleState.resumed) {
      cameraInitialization = initializeCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    super.dispose();
  }

  Future<void> capture() async {
    final activeController = controller;
    if (activeController == null || !activeController.value.isInitialized || activeController.value.isTakingPicture) return;
    XFile photo;
    try {
      photo = await activeController.takePicture();
    } on CameraException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.description ?? 'Could not capture the tray.')));
      return;
    }
    await processImage(photo.path);
  }

  Future<void> choosePhoto() async {
    final photo = await picker.pickImage(source: ImageSource.gallery, imageQuality: 100);
    if (photo != null) await processImage(photo.path);
  }

  Future<void> processImage(String imagePath) async {
    if (processing) return;
    setState(() => processing = true);
    try {
      final result = await VisionScannerService.instance.analyzeTray(imagePath);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onProcessed(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => processing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not process the tray: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Capture tray'), leading: const BackButton()),
        body: processing ? const _ProcessingView() : Column(children: [
          Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Fit the tray or device inside the frame', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Keep all four tray edges visible. Hold steady and avoid glare on the labels.', style: TextStyle(color: Color(0xff505565), height: 1.35)),
            const SizedBox(height: 20),
            Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(24), child: _CameraPreview(controller: controller, error: cameraError))),
          ]))),
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), child: Row(children: [
            Expanded(child: FilledButton.icon(onPressed: controller?.value.isInitialized == true ? capture : null, icon: const Icon(Icons.camera_alt_outlined), label: const Padding(padding: EdgeInsets.symmetric(vertical: 15), child: Text('Take photo')))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(onPressed: choosePhoto, icon: const Icon(Icons.photo_library_outlined), label: const Padding(padding: EdgeInsets.symmetric(vertical: 15), child: Text('Choose photo')))),
          ])),
        ]),
      );
}

class _CameraPreview extends StatelessWidget {
  const _CameraPreview({required this.controller, required this.error});
  final CameraController? controller;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) return _CameraMessage(icon: Icons.no_photography_outlined, title: 'Camera unavailable', detail: error!);
    final activeController = controller;
    if (activeController == null || !activeController.value.isInitialized) return const _CameraMessage(icon: Icons.camera_alt_outlined, title: 'Starting camera…', detail: 'Allow camera access when your phone asks.');
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(activeController),
      IgnorePointer(child: CustomPaint(painter: _TrayGuidePainter())),
      const Positioned(left: 16, right: 16, bottom: 16, child: Text('Fit the tray or device inside the guide', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, shadows: [Shadow(blurRadius: 4)]))),
    ]);
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage({required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xff202331),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white70, size: 44),
                const SizedBox(height: 12),
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, height: 1.35)),
              ],
            ),
          ),
        ),
      );
}

class _TrayGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2;
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .1, size.height * .12, size.width * .8, size.height * .68), const Radius.circular(14));
    canvas.drawRRect(rect, paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ProcessingView extends StatelessWidget {
  const _ProcessingView();

  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        const Text('Finding barcodes and IMEIs', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Checking barcode and printed IMEI evidence. This usually takes a few seconds.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xff505565), height: 1.35)),
      ])));
}

class ReviewPage extends StatefulWidget {
  const ReviewPage({required this.trayNumber, required this.cells, required this.onCellsChanged, required this.onRescan, required this.onNextTray, super.key});
  final int trayNumber;
  final List<DemoCell> cells;
  final ValueChanged<List<DemoCell>> onCellsChanged;
  final VoidCallback onRescan;
  final VoidCallback onNextTray;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  @override
  Widget build(BuildContext context) {
    final accepted = widget.cells.where((cell) => cell.status == CellStatus.accepted).length;
    final unresolved = widget.cells.length - accepted;
    return Scaffold(
      appBar: AppBar(title: Text('Tray ${widget.trayNumber}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)), leading: const BackButton()),
      body: ListView(padding: const EdgeInsets.fromLTRB(22, 8, 22, 24), children: [
        ExpansionPanelList.radio(
          initialOpenPanelValue: widget.trayNumber,
          elevation: 0,
          expandedHeaderPadding: EdgeInsets.zero,
          dividerColor: const Color(0xffe3e3e3),
          children: [
            _trayPanel(widget.trayNumber, 'Tray ${widget.trayNumber}', widget.cells, accepted, unresolved, onRescan: widget.onRescan),
            _trayPanel(1, 'Tray 1', widget.cells, accepted, unresolved),
            _trayPanel(2, 'Tray 2', widget.cells, accepted, unresolved),
          ],
        ),
      ]),
      bottomNavigationBar: SafeArea(child: _BottomActions(sessionState: SessionState.active, onStart: _noop, onScan: widget.onNextTray, onEnd: () => Navigator.of(context).pop())),
    );
  }

  ExpansionPanelRadio _trayPanel(int value, String label, List<DemoCell> trayCells, int accepted, int unresolved, {VoidCallback? onRescan}) => ExpansionPanelRadio(
        value: value,
        canTapOnHeader: true,
        headerBuilder: (_, isExpanded) => SizedBox(height: 68, child: Align(alignment: Alignment.centerLeft, child: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)))),
        body: Padding(padding: const EdgeInsets.only(bottom: 24), child: Column(children: [
          GridView.count(crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 1.28, children: trayCells.map((cell) => _HiFiReviewCell(cell: cell, onTap: () => _showCellDetails(context, cell))).toList()),
          const SizedBox(height: 18),
          Row(children: [Expanded(child: _ReviewSummary(label: 'Successful', value: '$accepted', color: const Color(0xffdff0df))), const SizedBox(width: 10), Expanded(child: _ReviewSummary(label: 'Error', value: '$unresolved', color: const Color(0xfffff2c8))), const SizedBox(width: 12), SizedBox(width: 112, height: 48, child: FilledButton(onPressed: onRescan, style: FilledButton.styleFrom(backgroundColor: const Color(0xffef5a60), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Re-scan', style: TextStyle(fontWeight: FontWeight.w700))))]),
        ])),
      );

  static void _noop() {}

  void _showCellDetails(BuildContext context, DemoCell cell) => showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (_) => Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(cell.position, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)), const SizedBox(height: 8), Text(cell.reason, style: const TextStyle(color: Color(0xff505565))), const SizedBox(height: 18), Text(cell.imei ?? 'No accepted IMEI', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)), const SizedBox(height: 18), SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(context), child: Text(cell.status == CellStatus.accepted ? 'Close' : 'Retake this position')))])));
}

class _HiFiReviewCell extends StatelessWidget {
  const _HiFiReviewCell({required this.cell, required this.onTap});
  final DemoCell cell;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accepted = cell.status == CellStatus.accepted;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(7), child: Container(decoration: BoxDecoration(color: accepted ? const Color(0xfff4f4f4) : const Color(0xfffff4c9), borderRadius: BorderRadius.circular(7)), child: Column(children: [Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 6), decoration: const BoxDecoration(color: Color(0xffe1eff4), borderRadius: BorderRadius.vertical(top: Radius.circular(7))), child: Text(cell.position, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xff247aa0), fontSize: 13))), Expanded(child: Center(child: Text(accepted ? cell.imei ?? '—' : 'Not Detected', textAlign: TextAlign.center, maxLines: 2, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accepted ? Colors.black : const Color(0xffbd8c00)))))])));
  }
}

class _ReviewSummary extends StatelessWidget { const _ReviewSummary({required this.label, required this.value, required this.color}); final String label; final String value; final Color color; @override Widget build(BuildContext context) => Container(height: 48, padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)), child: Row(children: [Expanded(child: Text(label, style: const TextStyle(fontSize: 13))), Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))])); }
class _CollapsedTray extends StatelessWidget { const _CollapsedTray({required this.label}); final String label; @override Widget build(BuildContext context) => Container(height: 68, decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xffe4e4e4)))), child: Row(children: [Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const Spacer(), const Icon(Icons.keyboard_arrow_down)])); }

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 28), children: [const Text('Batches', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)), const SizedBox(height: 6), const Text('Recent tray scans and sync status.', style: TextStyle(color: Color(0xff505565))), const SizedBox(height: 24), const _BatchRow(tray: 'TRAY-024', time: 'Today, 10:42 AM', detail: '15 of 15 verified', state: 'Synced'), const SizedBox(height: 8), const _BatchRow(tray: 'TRAY-023', time: 'Today, 10:18 AM', detail: '14 verified · 1 review', state: 'Review', warning: true), const SizedBox(height: 8), const _BatchRow(tray: 'TRAY-022', time: 'Today, 9:51 AM', detail: '15 of 15 verified', state: 'Synced')]);
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: Color(0xff606575)));
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.warning = false});
  final String label;
  final String value;
  final bool warning;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.fromLTRB(12, 14, 12, 12), decoration: BoxDecoration(color: warning ? const Color(0xfffff3d8) : Colors.white, borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: warning ? const Color(0xff9a6500) : const Color(0xff252937))), const SizedBox(height: 3), Text(label, style: const TextStyle(fontSize: 11, color: Color(0xff606575)))]));
}

class _BatchRow extends StatelessWidget {
  const _BatchRow({required this.tray, required this.time, required this.detail, required this.state, this.warning = false});
  final String tray;
  final String time;
  final String detail;
  final String state;
  final bool warning;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Row(children: [Icon(warning ? Icons.warning_amber_rounded : Icons.check_circle_outline, color: warning ? const Color(0xff9a6500) : const Color(0xff177245)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tray, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 3), Text('$detail · $time', style: const TextStyle(color: Color(0xff606575), fontSize: 12))])), Text(state, style: TextStyle(color: warning ? const Color(0xff9a6500) : const Color(0xff177245), fontWeight: FontWeight.w700, fontSize: 12))]));
}
