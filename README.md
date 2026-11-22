# Vanish Class Network

## Setup and Run

**Platform:** Android  
**Framework:** Flutter  
**Language:** Dart

### Relay Address

`wss://vanish-relay-sawaira.bonto.page/ws`

**Protocol:** WebSocket, JSON text frames  
**Protocol Version:** 1

See [PROTOCOL.md](PROTOCOL.md) for protocol details.

### Requirements

- Flutter SDK
- Android Studio or VS Code
- Android device or emulator

### Build and Run

Run these commands one by one:

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

### Build APK

To generate a debug APK:

```bash
flutter build apk --debug
```

**APK Location:**

`build/app/outputs/flutter-apk/app-debug.apk`