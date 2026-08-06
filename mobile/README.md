# MultiScan mobile

## Google Sheets connection setup

The app now supports this flow:

1. Tap **Connect Google Sheets**.
2. Sign in with Google.
3. Approve spreadsheet and read-only Drive access.
4. Choose a spreadsheet from the account.
5. The selected spreadsheet name appears in the linked-status row.

The implementation uses `google_sign_in` for user OAuth and the Drive files API to list only non-trashed Google Sheets. It does not ship a service-account key in the app.

Before testing on iOS, create or configure an OAuth client for the app in Google Cloud/Firebase and add the iOS client configuration to `ios/Runner/Info.plist`:

```xml
<key>GIDClientID</key>
<string>YOUR_IOS_CLIENT_ID</string>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>YOUR_REVERSED_CLIENT_ID</string>
    </array>
  </dict>
</array>
```

Alternatively, pass the iOS client ID at build time:

```bash
flutter run --dart-define=GOOGLE_IOS_CLIENT_ID=YOUR_IOS_CLIENT_ID
```

The reversed client ID URL scheme is still required in `Info.plist` so iOS can return to the app after Google authentication.
