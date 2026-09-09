# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Transcriber is a macOS menu-bar app (Swift, SwiftPM, macOS 14.2+) that records microphone
and system audio, transcribes locally with FluidAudio / Parakeet, separates speakers and
writes the transcript live to disk. Everything runs offline except the model download.
Code and comments are in English.

## Commands

There are no unit tests (no `Tests/` target). Verification is `swift build` plus the
headless self-test modes of the binary below.

```sh
swift build                              # quick compile check (debug)
./scripts/bundle.sh                      # release build → dist/Transcriber.app (signed)
./scripts/bundle.sh debug                # debug bundle, leaves /Applications instance alone
./scripts/bundle.sh release --install    # build, copy to /Applications, relaunch
./scripts/release.sh 0.4.0 "notes"       # bump Info.plist, CHANGELOG, tag vX.Y.Z, build, zip, gh release
```

`bundle.sh` needs no Xcode, only the Command Line Tools. Do not assume `xcodebuild` or
`xcodegen` are installed. It signs with the self-signed identity **Transcriber Dev** if
present (stable signature keeps the mic / system-audio TCC grants across rebuilds);
override with `CODESIGN_IDENTITY`. `release.sh` refuses a dirty tree and pushes the tag
before the GitHub release, so fetch/rebase `main` first.

### Headless modes of the binary

`main.swift` dispatches on these flags before AppKit starts. Launch via `open -a … --args`
(not the bare binary) whenever permissions matter, so TCC attributes them to the bundle.

```sh
# end-to-end recording through the real RecordingCoordinator, no UI
open -a /Applications/Transcriber.app --args --record-test 20 --log /tmp/record.log
# permissions, callback counts and peak levels for mic + system tap
open -a /Applications/Transcriber.app --args --capture-test 8 --log /tmp/capture.log
# VAD → ASR → SessionStore pipeline over an audio file (pipeline testing, re-transcribing)
.build/release/Transcriber --transcribe file.wav [--language de] [--out dir] [--diarize] [--reference system.wav] [--realtime]
# offline long-window re-pass (the RecordingFinalizer path); use to A/B quality vs. the line above
.build/release/Transcriber --transcribe file.wav --longwindow [--window 600] [--language de]
# marketing images rendered from the real PillView / FloatingBarView (used by .github/workflows/hero-render.yml)
.build/release/Transcriber --render-hero out.png --timer 12:34 --caption "…" "Anna: line" "Me: line"
.build/release/Transcriber --render-bar out.png --text "…"
```

### UI development flags (normal app launch)

`--settings [section]` opens Settings, `--changelog` the What's New window, `--start`
records immediately, `--cycle` records/stops/records, `--title-test` shows the save
prompt, `--bar-test [--bar-offset 80]` shows the paused floating bar without recording
and skips login item, model preload, update check and recovery prompt so it can run
next to the installed app (`open -n dist/Transcriber.app --args --bar-test --bar-offset 90`).

Logs: `~/Library/Logs/Transcriber.log` (`AppLog`). Settings live in `UserDefaults` for
bundle id `com.moritzkrause.anyrecord` (historic name, do not change: it is tied to
permissions and the login item).

## Architecture

Single executable target in `Sources/Transcriber`; `Resources/Info.plist` is linked into
the bare binary via `-sectcreate` so `swift run` already carries bundle id and usage strings.

**Data flow of a recording** (`Recording/RecordingCoordinator.swift`, `@MainActor`):

1. `ModelCache` hands out the preloaded `FluidAudioEngine` (Parakeet, CoreML) and Silero
   VAD; `ModelManager` owns download/availability state. Models are downloaded only on
   explicit action (first recording, Settings), never by the preload.
2. `MicrophoneCapture` (AVAudioEngine) and `SystemAudioCapture` (Core Audio process tap
   on a private aggregate device) deliver 16 kHz mono Float32 with host timestamps. Both
   captures are restarted on device changes; the system tap is rebuilt when the audio
   process list changes (see the macOS 26 note in `SystemAudioCapture.swift`).
3. `EchoGate` mutes mic frames that are only loudspeaker echo, using the system channel as
   reference (delay + gain estimation on 20 ms frames aligned by host time).
4. One `ChannelProcessor` per channel (`.me` = mic, `.them` = system) runs streaming VAD
   and cuts speech segments with session-relative timestamps.
5. `TranscriptionQueue` serializes ASR for both channels (Neural Engine gains nothing from
   parallelism), emits partials for the UI and finals in submission order.
6. Finals go to `SessionStore` (append + fsync `transcript.jsonl`, re-render
   `transcript.md`); `EchoDeduplicator` drops mic finals that repeat the far end's text.
   Raw audio is written by `WavWriter`.
7. On stop, `RecordingFinalizer` runs the shared end-of-session steps: pyannote
   diarization of the system channel (`RemoteDiarizer`), relabelling, exports
   (`TranscriptExporter`), optional title prompt (inside the floating bar), cleanup.
   `SessionRecovery` reuses the same finalizer for sessions left in `recording` state
   after a crash.

**UI** is driven entirely by `AppState` (`@MainActor ObservableObject`, single source of
truth: phase, levels, live/partial lines, retractions). `StatusItemController` + `PillView`
render the menu bar dot/pill, `FloatingBarController` the live transcript capsule (a
fixed-size transparent `NSPanel`; only the SwiftUI capsule inside morphs), `SettingsView`
the settings. `AppSettings.shared` wraps `UserDefaults`. `FloatingBarController.shared`
exists so the finalizer can ask for the title inside the bar.

**Partial text stability** logic (which words are shown blurred vs. settled, holding back
mic words while the far end talks) lives in the coordinator's queue callbacks, not in the
views. It is display-only; files always use the final pass.

**System integration** (`System/`): global hotkey ⌃⌥⌘R (Carbon), `CallDetector` (another
process opening the mic triggers a notification), `PowerAssertion`, `LaunchAtLogin`,
`ConsentNotice`, `UpdateChecker` (GitHub releases API, verifies the update carries the same
signing identity before swapping), `AITool` (hand transcript to a website/app via URL or
clipboard paste). `Permissions.swift` calls the private `TCCAccessRequest` for system audio;
this is intentional and not App Store compatible.

**Threading:** coordinator, state and UI are main-actor; audio callbacks arrive on
Core Audio threads and hand samples to processors/VAD; ASR runs off-main through the
queue. Keep heavy setup/teardown off the main thread (`offMain`) so the pill animation
does not stutter.

## Keep the README current

After any significant change, update [README.md](README.md) in the same session so it
never lags behind the code. Treat this as part of the task, not a follow-up.

Update the README when you:

- add or meaningfully change a **feature** (recording, transcription, speaker
  separation, the floating bar, settings, exports, AI hand-off, updates, …)
- add or change a **user-facing workflow** (build/install/release steps, launch flags,
  first-run or permission flow, output layout, keyboard shortcuts)
- add or change a **developer workflow** worth documenting (scripts, self-tests,
  diagnosing audio capture, code signing)
- change **requirements** (macOS version, hardware, dependencies)

Match the existing section (Requirements, Build, Usage, Output, How speakers are
separated, Implementation notes, Project layout, …); add a new section only when none
fits. Keep the README's calm, factual tone and its existing depth – describe what the
user sees and does, not the implementation detail.

Skip the README only for pure bug fixes, refactors, or internal changes with no
user- or developer-visible effect. When in doubt, add it. If a change is worth a
CHANGELOG entry, it is almost certainly worth a README check.

## CHANGELOG

`CHANGELOG.md` is shipped inside the app (Settings → General → Show Changes).
`release.sh` adds a section from the release notes unless one for that version already
exists. Entries: one short bullet per user-visible change.
