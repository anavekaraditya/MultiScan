# MultiScan mobile

## iOS Vision scanner and laptop dashboard

The scanner runs locally on iOS using Apple Vision. A laptop dashboard can be
opened on the same Wi-Fi network. Each scan is sent to a selected dashboard
session, where accepted IMEIs appear live in a copyable list. Duplicate IMEIs
are intentionally preserved. Unresolved or conflicting cells remain in the
local review screen and are not counted as accepted IMEIs.

The scanner accepts either:

- a photo of one device or one label; or
- a photo of the full tray.

Vision scans the complete image for all barcode payloads and printed text. A
single-device photo produces only the detected positions (`P1`, `P2`, ...).
For multiple devices, detected coordinates are clustered into rows and
columns automatically; a normal 15-device tray will produce positions such as
`R1C1` through `R5C3`, while other layouts are also supported. Candidates
must be 15 digits and pass the IMEI Luhn check. Barcode/OCR disagreements
remain in review instead of being silently accepted.

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

## Laptop dashboard setup

Start the backend on the laptop:

```bash
cd backend
python3 -m pip install -r requirements.txt
uvicorn multiscan_api.main:app --host 0.0.0.0 --port 8000
```

On the laptop, open `http://127.0.0.1:8000/dashboard` and create a session.
On the iPhone, tap **Laptop Dashboard** and enter the laptop’s local IP address
(for example `http://192.168.1.10:8000`) plus the displayed session code.

For the first accuracy pass, collect labeled examples for every physical tray
position, including rotated labels, glare, blur, missing devices, and damaged
labels. The attached images are smoke-test fixtures only and do not provide a
complete ground-truth manifest.
