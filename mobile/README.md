# MultiScan mobile

## iOS Vision scanner

The current prototype scans locally on iOS using Apple Vision. Google Sheets,
cloud processing, and Android recognition are intentionally disabled for this
phase.

The scanner accepts either:

- a photo of one device or one label; or
- a photo of the full tray.

Vision scans the complete image for all barcode payloads and printed text. A
single-device photo produces only the detected positions (`P1`, `P2`, ...).
When enough spatial evidence indicates a tray, the results are mapped to the
15-cell layout (`R1C1` through `R5C3`). Candidates must be 15 digits and pass
the IMEI Luhn check. Barcode/OCR disagreements remain in review instead of
being silently accepted.

## Test on an iPhone

From the project root:

```bash
cd mobile
flutter clean
flutter pub get
cd ios
pod install
cd ..
flutter run -d <your-iphone>
```

Allow camera and photo-library access when prompted. Tap **Start Session**,
then **Scan**. Use **Take photo** for a new capture or **Choose photo** to
select a tray or close-up label from Photos. The scan is saved locally in the
app’s SQLite database, including the original image reference and each result.

For the first accuracy pass, collect labeled examples for every physical tray
position, including rotated labels, glare, blur, missing devices, and damaged
labels. The attached images are smoke-test fixtures only and do not provide a
complete ground-truth manifest.
