# AnyRecord

Menu bar app for macOS that records calls (microphone + system audio), transcribes
them locally with FluidAudio / Parakeet, separates speakers and saves the transcript
live to a folder of your choice. Works with any app: Zoom, Teams, Meet, WhatsApp,
FaceTime, browsers, YouTube – anything that plays audio.

Everything runs offline. The only network access is the one-time model download.

## Requirements

- macOS 14.2 or newer (Core Audio process taps), Apple Silicon recommended
- Xcode 15.2+ **or** just the Command Line Tools (`xcode-select --install`)

## Build

Option A – Xcode: open `Package.swift` in Xcode, select the *AnyRecord* scheme, run.

Option B – terminal, produces a double-clickable app in `dist/`:

```sh
./scripts/bundle.sh          # release build + AnyRecord.app
open dist/AnyRecord.app
```

Option C – generate an `.xcodeproj` (optional): `brew install xcodegen && xcodegen`.

`./scripts/bundle.sh release --install` additionally copies the app to /Applications
and relaunches it.

Running the bare binary (`swift run`) works too, but macOS remembers microphone /
system-audio permissions and "Launch at login" only for a real `.app` bundle.

### Code signing and permissions

macOS ties privacy grants to the app's code signature. An ad-hoc signature changes
with every build, so the microphone / system-audio permissions would be reset after
each rebuild. `bundle.sh` therefore signs with a self-signed identity named
**AnyRecord Dev** when one exists in the login keychain (create one once via
Keychain Access › Certificate Assistant › Create a Certificate, type "Code Signing",
or with `openssl` + `security import`). Set `CODESIGN_IDENTITY` to use a different
identity, e.g. a Developer ID.

### Logs and self-tests

The app writes `~/Library/Logs/AnyRecord.log` (device, formats, tap, echo-gate stats
every 30 s, restarts). Two self-tests exist:

```sh
# full recording session without UI (uses the real coordinator, echo gate, ASR)
open -a /Applications/AnyRecord.app --args --record-test 20 --log /tmp/record.log
sleep 50; cat /tmp/record.log
```

### Diagnosing audio capture

```sh
open -a /Applications/AnyRecord.app --args --capture-test 8 --log /tmp/capture.log
sleep 25; cat /tmp/capture.log
```

prints permission state, callback counts and peak levels for the microphone and the
system audio tap. Launch it via `open` (not directly) so permissions are attributed to
the app bundle.

## First run

1. macOS asks for **Microphone** and **System Audio Recording** permission.
   Both are needed (System Settings › Privacy & Security).
2. The first recording downloads the models (~1 GB, Parakeet TDT v3 + Silero VAD +
   pyannote diarization) into `~/Library/Application Support/FluidAudio/Models`.
   You can also download them up front in Settings › Transcription.

## Usage

- **Left click** the dot in the menu bar: start recording. The dot turns red and
  expands into a pill with a live waveform and timer.
- **Left click again**: stop and save.
- **Right click**: menu with Settings, transcripts folder, quit.
- **⌃⌥⌘R**: global shortcut to start / stop.
- A floating bar below the menu bar / notch shows the live transcript (can be
  turned off in Settings).

## Output

Each recording gets a folder `<Transcripts>/<yyyy-MM-dd HH-mm> <title>/`:

| File | Purpose |
| --- | --- |
| `transcript.md` | Readable transcript, grouped by speaker with timestamps. Re-rendered after every segment. |
| `transcript.jsonl` | One JSON object per segment, appended and fsync'ed immediately. This is the crash-safe source of truth. |
| `transcript.json`, `transcript.srt` | Optional exports (Settings › Output). |
| `mic.wav`, `system.wav` | Raw 16 kHz mono audio, flushed every 2 s. Optional to keep. |
| `session.json` | Metadata and status (`recording` / `complete`). |

If the Mac crashes mid-call, the transcript up to the last segment is already on
disk. On the next launch AnyRecord offers to finalize the session: it transcribes
the audio that was not processed yet and renders the final files.

## How speakers are separated

- Microphone channel → you (label configurable).
- System audio channel → the other side. After the call, pyannote diarization
  runs over that channel and splits it into "Speaker 1", "Speaker 2", … when
  several remote voices are detected.
- **Echo gate** (on by default): without headphones your microphone also hears the
  loudspeaker, so the far end would be transcribed twice. The gate uses the system
  audio channel as reference, estimates delay and echo gain, and mutes mic frames
  that only contain the far end. A text-level check drops any remaining duplicates.
  On a real 54-minute Zoom call this removed 220 of 225 echo segments.
- Apple voice processing is available as an experimental alternative (off by default).

## Implementation notes

- **System audio tap on macOS 26:** a global tap (`stereoGlobalTapButExcludeProcesses`)
  is created without error but its aggregate device never starts IO. A mixdown tap
  over the explicit list of audio process objects works, so AnyRecord uses that and
  rebuilds the tap when the process list changes (apps launched mid-recording).
- **System audio permission:** there is no public API to trigger the prompt, so the
  app calls the private `TCCAccessRequest` for `kTCCServiceAudioCapture` (fine for a
  personal build, not App Store compatible).

## Project layout

```
Sources/AnyRecord
├── App/            entry point, AppDelegate, AppState, AppSettings
├── Audio/          Core Audio devices, microphone capture, system audio tap, resampler, WAV writer
├── Transcription/  ModelManager, FluidAudio engine, VAD segmenter, transcription queue, diarizer
├── Storage/        SessionStore (JSONL/MD), exporters, crash recovery
├── Recording/      RecordingCoordinator (orchestration), RecordingFinalizer
├── System/         hotkey, power assertion, launch at login, call detection, consent notice
└── UI/             status item + pill/waveform, floating bar, settings window
```

## Legal

Recording conversations without consent is illegal in many jurisdictions
(e.g. § 201 StGB in Germany). Inform participants before recording.
