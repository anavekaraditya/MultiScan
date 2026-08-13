# MultiScan Vercel deployment

This folder is a standalone deployment target for the laptop dashboard and its
temporary session API.

## Important data behavior

This version does **not** permanently save IMEIs or session codes. Data lives in
the running Python process and disappears when that process restarts or is
replaced. That is suitable for testing, but it is not a durable production
database.

## Deploy from this Git repository

1. Push the repository to GitHub, GitLab, or Bitbucket.
2. In Vercel, choose **Add New → Project** and import the repository.
3. In **Root Directory**, choose `vercel`.
4. Leave **Framework Preset** as `Other`.
5. Leave **Build Command** empty.
6. Leave **Output Directory** empty.
7. Leave **Install Command** as the default.
8. Click **Deploy**.

Vercel will use `vercel.json`, `api/index.py`, and `requirements.txt`.

## Test the deployment

Open:

```text
https://YOUR-PROJECT.vercel.app/dashboard
```

Click **New session**. Enter the resulting session code and this same base URL
in the iPhone app. Do not use `127.0.0.1` or the laptop's local IP for a hosted
deployment.

## Scan a digital barcode sheet

After creating a session, use **Scan a barcode sheet → Choose image**. The
dashboard processes JPG, PNG, and WebP files locally in the browser, so the
original image is not uploaded to the Vercel function. The scanner uses
overlapping image tiles, an enhanced contrast pass, barcode decoding, optional
OCR verification, Luhn validation, duplicate detection, and inferred row and
column positions. Only results with independent confirmation are marked
accepted; single reads remain in review and are not appended.

Use the **Rows** and **Columns** fields when the sheet layout is known. This
helps keep positions stable when one barcode is missing. The **Append accepted**
button adds accepted document results to the same session as the phone scanner.
Phone batches continue to appear through the existing polling flow.

The current document mode accepts image files only. For best results, export a
flatbed scan at 300–600 DPI rather than a screenshot or compressed photo. The
barcode and OCR engines are loaded from pinned public CDNs on first use, so the
laptop needs internet access for the first document scan.

## Limitations of the temporary mode

- Sessions can disappear when the server is restarted or scaled.
- A session is not shared across separate in-memory function instances.
- The dashboard refreshes every two seconds instead of using WebSockets.
- Do not use this mode as the system of record for operational IMEI data.

When you are ready for reliable multi-device use, replace `SessionStore` with a
short-TTL Redis store. That can still automatically delete session data without
creating a permanent IMEI archive.
