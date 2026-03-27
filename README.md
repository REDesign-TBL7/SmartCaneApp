# SmartCaneApp

An iOS SwiftUI prototype for a smart white cane assistive device.

## Current Scope

- Blind-first home screen with actionable status controls
- Destination search using Apple location APIs
- Local persistence for saved places and trip stats
- Spoken updates through `AVSpeechSynthesizer`
- Wi-Fi cane connection manager placeholder for Raspberry Pi Zero integration

## Project Structure

```text
SmartCaneApp/
├── App/
├── Managers/
├── Models/
└── Views/
```

## Important Placeholder

The future Wi-Fi transport layer for sending `LEFT`, `RIGHT`, `FORWARD`, and `STOP`
to the Raspberry Pi Zero is currently stubbed in:

- `SmartCaneApp/Managers/CaneConnectionManager.swift`

## Running

1. Open `SmartCaneApp.xcodeproj` in Xcode.
2. Choose an iPhone simulator or your physical iPhone.
3. Build and run the `SmartCaneApp` scheme.

