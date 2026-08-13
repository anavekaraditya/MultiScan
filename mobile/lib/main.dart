import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'services/scan_store.dart';
import 'services/dashboard_sync_service.dart';
import 'services/vision_scanner_service.dart';

void main() => runApp(const MultiScanApp());

enum CellStatus { accepted, retake, review }

class DemoCell {
  const DemoCell(this.position, this.status, this.imei, this.reason, {this.source = 'none', this.confidence = 0, this.boxes = const []});
  final String position;
  final CellStatus status;
  final String? imei;
  final String reason;
  final String source;
  final double confidence;
  final List<VisionBox> boxes;
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
  Widget build(BuildContext context) => Scaffold(backgroundColor: const Color(0xff061b42), body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Image.asset('assets/multiscan_logo.png', width: 210, height: 210, fit: BoxFit.contain), const SizedBox(height: 18), const Text('MultiScan', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700))])));
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool dashboardLinked = false;
  bool connectingDashboard = false;
  int currentSessionDevices = 0;
  int totalDevicesScanned = 0;
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
      final total = await ScanStore.instance.loadTotalAccepted();
      if (mounted) setState(() { recentScans = recent; totalDevicesScanned = total; });
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

  void openCapture({bool replaceCurrent = false, bool nextTray = false}) {
    final scanTrayNumber = activeTrayNumber + (nextTray ? 1 : 0);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CapturePage(onProcessed: (result) => openReview(result, trayNumber: scanTrayNumber, replaceCurrent: replaceCurrent))));
  }
  void openReview(VisionScanResult result, {required int trayNumber, required bool replaceCurrent}) {
    final scannedCells = result.cells.map(_toDemoCell).toList();
    final scanId = DateTime.now().microsecondsSinceEpoch.toString();
    unawaited(ScanStore.instance.saveScan(scanId: scanId, trayNumber: trayNumber, result: result));
    unawaited(_refreshRecentScans());
    final acceptedCount = scannedCells.where((cell) => cell.status == CellStatus.accepted).length;
    setState(() { cells = scannedCells; activeTrayNumber = trayNumber; currentSessionDevices += acceptedCount; totalDevicesScanned += acceptedCount; });
    HapticFeedback.heavyImpact();
    final unresolvedCount = scannedCells.length - acceptedCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          Icon(unresolvedCount == 0 ? Icons.verified_rounded : Icons.fact_check_outlined, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(child: Text(unresolvedCount == 0 ? '$acceptedCount devices verified.' : '$acceptedCount verified · $unresolvedCount need review.')),
        ]),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
    });
    if (dashboardLinked) unawaited(_syncToDashboard(result: result, batchId: scanId, trayNumber: trayNumber));
    final navigator = Navigator.of(context);
    if (replaceCurrent) navigator.pop();
    navigator.push(MaterialPageRoute(builder: (_) => ReviewPage(imagePath: result.imagePath, trayNumber: trayNumber, cells: cells, rawBarcodeCount: result.rawBarcodeCount, uniqueBarcodeCount: result.uniqueBarcodeCount, onCellsChanged: (value) => setState(() => cells = value), onRescan: () => openCapture(replaceCurrent: true), onNextTray: () => openCapture(nextTray: true))));
  }

  DemoCell _toDemoCell(VisionCellResult cell) => DemoCell(cell.position, switch (cell.status) {
        VisionCellStatus.accepted => CellStatus.accepted,
        VisionCellStatus.review => CellStatus.review,
        VisionCellStatus.retake => CellStatus.retake,
      }, cell.imei, cell.reason, source: cell.source, confidence: cell.confidence, boxes: cell.boxes);

  Future<void> _refreshRecentScans() async {
    final recent = await ScanStore.instance.loadRecent();
    if (mounted) setState(() => recentScans = recent);
  }
  Future<void> _syncToDashboard({required VisionScanResult result, required String batchId, required int trayNumber}) async {
    try {
      await DashboardSyncService.instance.syncScan(batchId: batchId, trayNumber: trayNumber, result: result);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scan synced to laptop dashboard.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scan saved locally. Dashboard sync failed: $error')));
    }
  }

  Future<void> connectDashboard() async {
    if (connectingDashboard) return;
    final sessionCode = await showDialog<String>(context: context, builder: (_) => const _DashboardConnectDialog());
    if (sessionCode == null || !mounted) return;
    setState(() => connectingDashboard = true);
    try {
      await DashboardSyncService.instance.connect(sessionCode: sessionCode);
      if (mounted) setState(() => dashboardLinked = true);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not connect to laptop dashboard: $error')));
    } finally {
      if (mounted) setState(() => connectingDashboard = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: HomePage(dashboardLinked: dashboardLinked, connectingDashboard: connectingDashboard, currentSessionDevices: currentSessionDevices, totalDevicesScanned: totalDevicesScanned, recentScans: recentScans, onConnectDashboard: connectDashboard, onScan: openCapture)));
}

class _DashboardConnectDialog extends StatefulWidget {
  const _DashboardConnectDialog();

  @override
  State<_DashboardConnectDialog> createState() => _DashboardConnectDialogState();
}

class _DashboardConnectDialogState extends State<_DashboardConnectDialog> {
  final codeController = TextEditingController();

  @override
  void dispose() {
    codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Connect laptop dashboard'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter the code shown on the laptop dashboard.', style: TextStyle(color: Color(0xff505565))),
          const SizedBox(height: 14),
          TextField(controller: codeController, autofocus: true, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Session code', hintText: 'ABC123')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(codeController.text), child: const Text('Connect')),
        ],
      );
}

class HomePage extends StatelessWidget {
  const HomePage({required this.dashboardLinked, required this.connectingDashboard, required this.currentSessionDevices, required this.totalDevicesScanned, required this.recentScans, required this.onConnectDashboard, required this.onScan, super.key});
  final bool dashboardLinked;
  final bool connectingDashboard;
  final int currentSessionDevices;
  final int totalDevicesScanned;
  final List<StoredScanSummary> recentScans;
  final VoidCallback onConnectDashboard;
  final VoidCallback onScan;
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
                    const Text('Ready to scan?', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Center(child: Column(children: [
                      const Text('Devices Scanned', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TweenAnimationBuilder<int>(
                        tween: IntTween(begin: 0, end: currentSessionDevices),
                        duration: const Duration(milliseconds: 520),
                        curve: Curves.easeOutCubic,
                        builder: (_, value, __) => Text('$value', style: const TextStyle(fontSize: 58, fontWeight: FontWeight.w500)),
                      ),
                    ])),
                    const SizedBox(height: 14),
                  ]),
                ),
                Transform.translate(offset: const Offset(0, -22), child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9), decoration: BoxDecoration(color: const Color(0xff326ca5), borderRadius: BorderRadius.circular(20)), child: const Text('Current Session', style: TextStyle(color: Colors.white, fontSize: 12))))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                  child: Column(children: [
                    Center(
                      child: FilledButton.icon(
                        onPressed: onScan,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                          child: Text('Scan tray', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(children: [
                      Expanded(child: _InfoCard(title: 'Laptop Dashboard', child: InkWell(onTap: onConnectDashboard, borderRadius: BorderRadius.circular(8), child: Row(children: [Icon(dashboardLinked ? Icons.laptop_mac : Icons.link_off, color: dashboardLinked ? const Color(0xff23739a) : const Color(0xff606575), size: 25), const SizedBox(width: 10), Expanded(child: Text(connectingDashboard ? 'Connecting…' : dashboardLinked ? 'Dashboard connected' : 'Tap to connect', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.15)))])))),
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

class _InfoCard extends StatelessWidget { const _InfoCard({required this.title, required this.child}); final String title; final Widget child; @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)), const SizedBox(height: 10), Container(width: double.infinity, height: 76, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: const Color(0xffe7f3f6), borderRadius: BorderRadius.circular(8)), child: child)]); }
class _ActivityRow extends StatelessWidget { const _ActivityRow({required this.date, required this.session, required this.devices}); final String date; final String session; final String devices; @override Widget build(BuildContext context) => Container(margin: const EdgeInsets.only(bottom: 7), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), decoration: BoxDecoration(color: const Color(0xfffbfbfb), borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Color(0x0c000000), blurRadius: 4, offset: Offset(0, 2))]), child: Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), decoration: BoxDecoration(color: const Color(0xffe2f0f5), borderRadius: BorderRadius.circular(9)), child: Text(date, style: const TextStyle(color: Color(0xff27759c), fontSize: 13))), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(session, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const Text('12:25 PM', style: TextStyle(fontSize: 11))])), Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(devices, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))))])); }
class _ReviewBottomAction extends StatelessWidget {
  const _ReviewBottomAction({required this.onNextTray});
  final VoidCallback onNextTray;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: onNextTray,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan next tray', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
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
      // Dense barcode sheets need as much still-image detail as the device can
      // provide. Vision performs better on the captured photo than on a live
      // preview, so use the highest practical camera preset here.
      final nextController = CameraController(backCamera, ResolutionPreset.veryHigh, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
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

  Future<void> liveScan() async {
    if (processing) return;
    final layout = await showDialog<_LiveLayout>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose tray layout'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LiveLayoutTile(layout: const _LiveLayout(rows: 3, columns: 5, label: '15 devices', detail: '3 × 5'), onTap: () => Navigator.pop(context, const _LiveLayout(rows: 3, columns: 5, label: '15 devices', detail: '3 × 5'))),
            const SizedBox(height: 10),
            _LiveLayoutTile(layout: const _LiveLayout(rows: 4, columns: 6, label: '24 devices', detail: '4 × 6'), onTap: () => Navigator.pop(context, const _LiveLayout(rows: 4, columns: 6, label: '24 devices', detail: '4 × 6'))),
            const SizedBox(height: 10),
            _LiveLayoutTile(layout: const _LiveLayout(rows: 4, columns: 16, label: '64 devices', detail: '4 × 16'), onTap: () => Navigator.pop(context, const _LiveLayout(rows: 4, columns: 16, label: '64 devices', detail: '4 × 16'))),
            const SizedBox(height: 10),
            _LiveLayoutTile(layout: const _LiveLayout(rows: 8, columns: 14, label: '112 devices', detail: '8 × 14'), onTap: () => Navigator.pop(context, const _LiveLayout(rows: 8, columns: 14, label: '112 devices', detail: '8 × 14'))),
          ],
        ),
      ),
    );
    if (layout == null || !mounted) return;
    setState(() => processing = true);
    try {
      final result = await VisionScannerService.instance.startLiveScan(rows: layout.rows, columns: layout.columns);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onProcessed(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => processing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Live scan unavailable: $error')));
    }
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
        backgroundColor: const Color(0xff101820),
        body: processing
            ? const _ProcessingView()
            : Stack(fit: StackFit.expand, children: [
                _CameraPreview(controller: controller, error: cameraError),
                const Positioned(top: 0, left: 0, right: 0, child: SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(22, 12, 22, 0), child: Text('Fit the tray or device inside the guide', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, shadows: [Shadow(blurRadius: 5)]))))),
                Positioned(top: 66, left: 0, right: 0, child: Center(child: FilledButton.icon(onPressed: liveScan, icon: const Icon(Icons.document_scanner_outlined), label: const Text('Live scan'), style: FilledButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white)))),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        _CaptureIconButton(icon: Icons.arrow_back_rounded, label: 'Back', onPressed: () => Navigator.of(context).pop()),
                        _ShutterButton(enabled: controller?.value.isInitialized == true, onPressed: capture),
                        _CaptureIconButton(icon: Icons.photo_library_outlined, label: 'Library', onPressed: choosePhoto),
                      ]),
                    ),
                  ),
                ),
              ]),
      );
}

class _LiveLayout {
  final int rows;
  final int columns;
  final String label;
  final String detail;
  const _LiveLayout({required this.rows, required this.columns, required this.label, required this.detail});
}

class _LiveLayoutTile extends StatelessWidget {
  final _LiveLayout layout;
  final VoidCallback onTap;
  const _LiveLayoutTile({required this.layout, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xffedf5f8), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.grid_view_rounded, color: Color(0xff23739a), size: 28),
            const SizedBox(width: 14),
            Expanded(child: Text(layout.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            Text(layout.detail, style: const TextStyle(color: Color(0xff52606d), fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.enabled, required this.onPressed});
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 86,
        height: 86,
        child: FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(backgroundColor: Colors.white, disabledBackgroundColor: Colors.white54, foregroundColor: const Color(0xff101820), padding: EdgeInsets.zero, shape: const CircleBorder(), side: const BorderSide(color: Colors.white, width: 4)),
          child: const Icon(Icons.camera_alt_rounded, size: 34),
        ),
      );
}

class _CaptureIconButton extends StatelessWidget {
  const _CaptureIconButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 76,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton.filledTonal(onPressed: onPressed, icon: Icon(icon, size: 25), style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white, minimumSize: const Size(52, 52), padding: EdgeInsets.zero)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4)])),
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

class _ProcessingView extends StatefulWidget {
  const _ProcessingView();

  @override
  State<_ProcessingView> createState() => _ProcessingViewState();
}

class _ProcessingViewState extends State<_ProcessingView> with SingleTickerProviderStateMixin {
  late final AnimationController _scanController;
  Timer? _messageTimer;
  int _messageIndex = 0;

  static const _messages = [
    'Finding every barcode in the image',
    'Checking close-up regions for missed labels',
    'Comparing barcode and printed IMEI evidence',
    'Validating the final candidates',
  ];

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _messageTimer = Timer.periodic(const Duration(milliseconds: 1450), (_) {
      if (mounted) setState(() => _messageIndex = (_messageIndex + 1) % _messages.length);
    });
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AnimatedBuilder(
              animation: _scanController,
              builder: (_, __) => Container(
                width: 188,
                height: 188,
                decoration: BoxDecoration(color: const Color(0xffeef7fa), borderRadius: BorderRadius.circular(28)),
                child: Stack(alignment: Alignment.center, children: [
                  const Icon(Icons.document_scanner_outlined, size: 76, color: Color(0xff2d679d)),
                  Positioned(
                    top: 22 + (_scanController.value * 128),
                    left: 22,
                    right: 22,
                    child: Container(height: 3, decoration: BoxDecoration(color: const Color(0xff80c900), borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Color(0x5580c900), blurRadius: 8)])),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 26),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Text(_messages[_messageIndex], key: ValueKey(_messageIndex), textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 10),
            const Text('This may take a few seconds while each region is checked.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xff505565), height: 1.35)),
          ]),
        ),
      );
}

class _ScanPreview extends StatelessWidget {
  const _ScanPreview({required this.imagePath, required this.cells});
  final String imagePath;
  final List<DemoCell> cells;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Scanned image', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 230,
            width: double.infinity,
            child: Stack(fit: StackFit.expand, children: [
              Image.file(File(imagePath), fit: BoxFit.fill, errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xffeeeeee), child: Center(child: Text('Scanned image unavailable')))),
              IgnorePointer(child: CustomPaint(painter: _DetectionBoxPainter(cells))),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        const Text('Colored boxes mark barcode/OCR regions used for the results below.', style: TextStyle(fontSize: 12, color: Color(0xff606575))),
      ]);
}

class _DetectionBoxPainter extends CustomPainter {
  const _DetectionBoxPainter(this.cells);
  final List<DemoCell> cells;

  @override
  void paint(Canvas canvas, Size size) {
    for (final cell in cells) {
      final color = switch (cell.status) {
        CellStatus.accepted => const Color(0xff25a55f),
        CellStatus.review => const Color(0xffffb400),
        CellStatus.retake => const Color(0xffef5a60),
      };
      final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5;
      for (final box in cell.boxes) {
        final rect = Rect.fromLTWH(box.x * size.width, box.y * size.height, box.width * size.width, box.height * size.height);
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter oldDelegate) => oldDelegate.cells != cells;
}

class ReviewPage extends StatefulWidget {
  const ReviewPage({required this.imagePath, required this.trayNumber, required this.cells, required this.rawBarcodeCount, required this.uniqueBarcodeCount, required this.onCellsChanged, required this.onRescan, required this.onNextTray, super.key});
  final String imagePath;
  final int trayNumber;
  final List<DemoCell> cells;
  final int rawBarcodeCount;
  final int uniqueBarcodeCount;
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
        _ScanPreview(imagePath: widget.imagePath, cells: widget.cells),
        const SizedBox(height: 8),
        Text('Vision found ${widget.uniqueBarcodeCount} unique barcode${widget.uniqueBarcodeCount == 1 ? '' : 's'} across ${widget.rawBarcodeCount} scan passes.', style: const TextStyle(fontSize: 12, color: Color(0xff606575))),
        const SizedBox(height: 18),
        ExpansionPanelList.radio(
          initialOpenPanelValue: widget.trayNumber,
          elevation: 0,
          expandedHeaderPadding: EdgeInsets.zero,
          dividerColor: const Color(0xffe3e3e3),
          children: [
            _trayPanel(widget.trayNumber, 'Tray ${widget.trayNumber}', widget.cells, accepted, unresolved, onRescan: widget.onRescan),
          ],
        ),
      ]),
      bottomNavigationBar: _ReviewBottomAction(onNextTray: widget.onNextTray),
    );
  }

  ExpansionPanelRadio _trayPanel(int value, String label, List<DemoCell> trayCells, int accepted, int unresolved, {VoidCallback? onRescan}) => ExpansionPanelRadio(
        value: value,
        canTapOnHeader: true,
        headerBuilder: (_, isExpanded) => SizedBox(height: 68, child: Align(alignment: Alignment.centerLeft, child: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)))),
        body: Padding(padding: const EdgeInsets.only(bottom: 24), child: Column(children: [
          GridView.count(crossAxisCount: _gridColumns(trayCells), shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 1.28, children: trayCells.map((cell) => _HiFiReviewCell(cell: cell, onTap: () => _showCellDetails(context, cell))).toList()),
          const SizedBox(height: 18),
          Row(children: [Expanded(child: _ReviewSummary(label: 'Successful', value: '$accepted', color: const Color(0xffdff0df))), const SizedBox(width: 10), Expanded(child: _ReviewSummary(label: 'Error', value: '$unresolved', color: const Color(0xfffff2c8))), const SizedBox(width: 12), SizedBox(width: 112, height: 48, child: FilledButton(onPressed: onRescan, style: FilledButton.styleFrom(backgroundColor: const Color(0xffef5a60), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Re-scan', style: TextStyle(fontWeight: FontWeight.w700))))]),
        ])),
      );

  int _gridColumns(List<DemoCell> trayCells) {
    final columns = trayCells.map((cell) => RegExp(r'C(\d+)$').firstMatch(cell.position)?.group(1)).whereType<String>().map(int.parse).fold<int>(0, (max, value) => value > max ? value : max);
    if (columns > 0) return columns.clamp(1, 5);
    return trayCells.length.clamp(1, 4);
  }

  void _showCellDetails(BuildContext context, DemoCell cell) => showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (_) => Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(cell.position, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)), const SizedBox(height: 8), Text(cell.reason, style: const TextStyle(color: Color(0xff505565))), const SizedBox(height: 18), Text(cell.imei ?? 'No detected value', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)), const SizedBox(height: 18), Row(children: [Expanded(child: OutlinedButton(onPressed: () async { Navigator.pop(context); await _editCell(cell); }, child: const Text('Correct value'))), const SizedBox(width: 10), Expanded(child: FilledButton(onPressed: () => Navigator.pop(context), child: Text(cell.status == CellStatus.accepted ? 'Close' : 'Retake')))])])));

  Future<void> _editCell(DemoCell cell) async {
    final controller = TextEditingController(text: cell.imei ?? '');
    final value = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: Text('Correct ${cell.position}'), content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.number, maxLength: 15, decoration: const InputDecoration(labelText: '15-digit value')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save'))]));
    controller.dispose();
    final digits = value?.replaceAll(RegExp(r'\D'), '') ?? '';
    if (digits.length != 15 || !mounted) return;
    final updated = widget.cells.map((item) => item.position == cell.position ? DemoCell(item.position, CellStatus.accepted, digits, 'Manually corrected', source: 'manual', confidence: 1, boxes: item.boxes) : item).toList(growable: false);
    widget.onCellsChanged(updated);
    setState(() {});
  }
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
