# The Agora LA - Interactive Podcast Prototype

This is a minimal SwiftUI prototype for an interactive podcast experience:
- Audio playback
- Timed prompts
- AI feedback + scoring (0-100)
- Points ledger
- Text + voice answers
- In-app prompt editor (no code edits)

## What You Get
- Themed UI (ancient Greek vibe)
- Prompt scheduler tied to timestamps
- Local scoring fallback with 0-100 scale
- Stub AI endpoint integration
- Points stored locally (UserDefaults)

## Setup (Xcode)
1. Open `/Users/shanereid/Documents/Codex/TheAgoraLA/TheAgoraLA.xcodeproj` in Xcode.
2. Press Run.
3. In the app, tap `Edit Episode & Prompts`, then paste your audio URL + prompts.

## Required Info.plist Keys
Add these to the app's Info.plist:
- `NSSpeechRecognitionUsageDescription` = "We use speech recognition to capture your answers."
- `NSMicrophoneUsageDescription` = "We use your microphone to record spoken answers."

## Where To Add Your Prompts
Use the in-app editor:
- Set your episode title
- Paste your MP3 URL
- Add timestamps/questions/expected answers

## AI Scoring Endpoint (Optional)
`AIService` will call a backend if you set `endpointURL`.
Expected POST payload:
- `question` (string)
- `expectedAnswer` (string)
- `userAnswer` (string)

Expected response:
- `score` (int 0-100)
- `feedback` (string)
- `awardedPoints` (int)

Without a backend, the app uses a local similarity score.

## Points System
Points are stored locally in `PointsStore` for now. When you stand up your server, this should be replaced with an authenticated ledger tied to Agora accounts.

## Next Steps
- Add authentication + account linking
- Add a backend service for scoring + points
- Add transcripts and prompt authoring UI
