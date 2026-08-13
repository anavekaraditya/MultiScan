# MultiScan

MultiScan is a high-reliability 3×5 tray scanner for device IMEIs. The repository contains a Flutter client foundation and a small Python recognition API.

## What is implemented

- Deterministic IMEI normalization and Luhn validation.
- Barcode/OCR evidence fusion with explicit `accepted`, `review`, and `retake` outcomes.
- Fixed `R1C1`–`R3C5` tray positions, duplicate detection, and idempotent device records.
- FastAPI-compatible `/v1/scan-batches` endpoint (FastAPI is an optional runtime dependency).
- Vercel dashboard supports local high-resolution barcode-sheet processing alongside live phone sessions.
- Flutter data models, review-oriented tray screen, local scan repository contract, and sync contract.

The barcode and OCR adapters are intentionally injected behind interfaces. Real device/image providers should be connected after representative label photos establish the exact barcode symbology and OCR thresholds. The API never silently accepts conflicting evidence.

## Backend

```bash
python3 -m unittest discover -s backend/tests -v
python3 -m pip install -r backend/requirements.txt
uvicorn multiscan_api.main:app --app-dir backend
```

## Mobile

Install Flutter, then run:

```bash
flutter pub get
flutter run
```

The current mobile shell demonstrates the tray review workflow with an injectable scan engine. Camera, ML Kit/Vision, SQLite, authentication, and Sheets implementations are isolated behind services so they can be added without changing the review model.
