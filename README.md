# Transcriber

A menu bar app for macOS that records a call (your microphone and the system audio),
transcribes it right on your machine with FluidAudio / Parakeet, tells the speakers
apart, and writes the transcript into a folder while the call is still going. It
doesn't care which app the sound comes from. Zoom, Teams, Meet, WhatsApp, FaceTime, a
browser tab, YouTube, anything that plays audio goes through the same path.

Everything happens offline. The only time it touches the network is the one-off model
download on first use. After that you can pull the cable.

I built this for myself, because I wanted call transcripts without handing my
conversations to some web service, and it turned out useful enough to put out here. If
that's the way you'd want to work, help yourself. If not, no hard feelings, there are
plenty of other transcribers around.

## Install

Most people never build anything. Grab the latest build from the
[Releases page](https://github.com/moritzjuliankrause/Transcriber/releases), unzip it,
and drag `Transcriber.app` into your Applications folder. You need macOS 14.2 or newer
(that's where the Core Audio process taps arrived), and Apple Silicon is the
comfortable case. No Xcode, no command line tools, nothing else to install.

One wrinkle: I haven't signed it with a paid Apple Developer ID yet, so the first time
you open it macOS calls it an unidentified developer and won't let it straight through.
Open it once through System Settings › Privacy & Security, where an "Open Anyway"
button turns up right after the block (on older macOS you right-click the app and pick
Open instead). After that it launches like anything else.

If you're on 0.5.0 or older, download 0.6.1 once by hand the same way: the built-in
updater will refuse it. I lost the certificate those versions were signed with, and the
updater only accepts the certificate it already knows. From 0.6.1 on, updates install
with one click again.

## Build from source

Only if you want to compile it yourself. You'll need:

- macOS 14.2 or newer (Core Audio process taps), Apple Silicon recommended
- Xcode 15.3+, or the matching Command Line Tools (`xcode-select --install`). The
  package is on Swift tools version 5.10, so anything older (Xcode 15.2 / Swift 5.9 and
  back) gets turned away before it compiles a line.

Three ways in.

Option A, in Xcode: open `Package.swift`, pick the *Transcriber* scheme, run.

Option B, in the terminal, which leaves you a double-clickable app in `dist/`:

```sh
./scripts/bundle.sh          # release build + Transcriber.app
open dist/Transcriber.app
```

Option C, generate an `.xcodeproj` if you'd rather (optional): `brew install xcodegen && xcodegen`.

`./scripts/bundle.sh release --install` does the same as Option B, then copies the app
to /Applications and relaunches it.

You can also run the bare binary with `swift run`, but macOS only remembers the
microphone and system-audio permissions and "Launch at login" for a real `.app`
bundle, so day to day the bundle is the nicer route.

With only the Command Line Tools installed, the macOS 27 SDK cannot compile SwiftUI's
`@State` (its macro plugin ships with Xcode). `bundle.sh` then builds against the newest
older SDK it finds; for a plain `swift build` set it yourself:
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build`.

### Code signing and permissions

macOS ties every privacy grant to the app's code signature. An ad-hoc signature
changes on every build, so your microphone and system-audio permissions would reset
each time you rebuild, which gets old fast. So `bundle.sh` signs with a self-signed
identity called **Transcriber Dev** when it finds one in your login keychain. You make
that identity once (Keychain Access › Certificate Assistant › Create a Certificate,
type "Code Signing", or with `openssl` plus `security import`). Set `CODESIGN_IDENTITY`
if you want to sign with something else, a Developer ID for instance.

### Logs and self-tests

The app keeps a log at `~/Library/Logs/Transcriber.log`: the device, the formats, the
tap, echo-gate stats every 30 s, and any restarts. The microphone engine is watched two
ways, a buffer that reads all zeros for 5 s and a complete stop in delivered buffers for
4 s, and either one restarts the input engine automatically (and says so in the log).
That's there so a mid-call device switch doesn't quietly kill your side of the
recording. There are two self-tests:

```sh
# full recording session without UI (uses the real coordinator, echo gate, ASR)
open -a /Applications/Transcriber.app --args --record-test 20 --log /tmp/record.log
sleep 50; cat /tmp/record.log
```

### Diagnosing audio capture

```sh
open -a /Applications/Transcriber.app --args --capture-test 8 --log /tmp/capture.log
sleep 25; cat /tmp/capture.log
```

This prints the permission state, callback counts, and peak levels for both the
microphone and the system-audio tap. Launch it through `open` rather than running the
binary directly, so the permissions land on the app bundle.

Both tests, and the `--start` / `--cycle` launch flags, record under the app's
microphone and system-audio permissions. Any program on the Mac could launch the app
with those flags, so a release build first asks "Start a recording?" and only records
after you click Record; a debug build skips the question.

## First run

1. macOS asks for **Microphone** and **System Audio Recording** permission. You need
   both (System Settings › Privacy & Security).
2. The first recording downloads the models (about 1 GB: Parakeet TDT v3, Silero VAD,
   and pyannote diarization) into `~/Library/Application Support/FluidAudio/Models`. If
   you'd rather not wait mid-call, pull them ahead of time in Settings › Transcription.

## Usage

- **Left click** the icon in the menu bar to start recording. The icon turns red.
- **Left click again** to stop and save (after a short confirmation in the floating pill).
- **Right click** for the menu: pause, mute, Settings, the transcripts folder, quit.
- **⌃⌥⌘R** starts and stops from anywhere.
- While recording, a **floating pill** sits under the menu bar (or the notch). You can
  turn it off in Settings › General. Its waveform shows that audio is coming in.
  - **Mute** (left button) mutes only your microphone. I use it to talk to someone in
    the room: the computer's audio is still recorded and transcribed, and my side is
    recorded as silence until I unmute.
  - **Pause** (right button) pauses the whole recording. Paused time is left out.
  - **Hover** the pill and the live transcript unfolds below it, a scrollable card with
    the conversation so far. The pill stays where it is, so the buttons never move
    under the pointer. The card opens at the latest line. Scroll up to read back; a
    "Latest" button shows up whenever you're not at the end. Click the waveform or the
    pin to keep the card open without hovering. The newest words stay blurred, often
    for several lines, until the model has heard enough of the sentence to be sure.
- **Name whoever is speaking** (Settings › Speakers, on by default). When the card opens
  on hover, the cursor is already in its "Who's speaking?" field. Type the name of
  whoever is talking on the far end and press Enter. Move the pointer away with the
  field empty and the keyboard goes back to the app in front; a half-typed name keeps
  the card open until Enter or Escape. It's meant for longer turns, someone giving a
  talk or presenting for a few minutes, not quick back-and-forth. Names you've used
  in the call show up as chips, so one click is enough when that person speaks again,
  and ✕ ends the name when they stop. Everything that voice says gets the name, live
  in the card and, after the call, across the whole recording: diarization finds the
  same voice everywhere, also where you didn't name it.
- **Re-transcribe after the call** (Settings › Transcription, off by default). When a
  recording stops, the recorded audio runs through the model again in long context
  windows and replaces the live transcript. The live pass works on single utterances,
  cut at pauses of about a second; the second pass feeds the model whole minutes at a
  time, so each word is heard inside its sentence. It's noticeably better on quick
  back-and-forth, and it finishes in well under a minute for an hour-long call.
- **Mute phases** are marked in the transcript where they happened
  (`[12:00–14:30] Microphone muted`).
- **Language** (Settings › Transcription): auto-detect or one of 18 languages. With
  Parakeet the choice keeps the model to the language's alphabet (no Cyrillic letters in
  Polish, no Latin in Russian). It can't force German over English, say; the model
  works out the language from the audio itself.

## Recordings: history, re-transcribing, importing

Settings › Recordings (also *Recordings…* in the menu) lists every recording with its
date, length and whether its audio is still around.

- **Re-transcribe** runs a finished recording through the after-call steps again with
  the current settings: long-window transcription of the kept audio, echo removal,
  speaker separation, remembered voices. Names already in the transcript are carried
  over by time, so speakers keep their names even if the numbering changes.
- **Transcribe an audio file.** Drop a WAV, M4A, MP3, AIFF or video file onto the
  section (or pick one) and it becomes a new recording named after the file, with every
  voice in it separated.
- **Unfinished recordings** (a crash, a forced quit) show up at the top with *Finalize*.
- **Keep raw audio** (Settings › Output): delete when saved, 7 days (the default), 30
  days, or until you delete it. Expired audio is removed automatically, at launch and
  every 6 hours; the transcript always stays. *Delete Audio* in a recording's ⋯ menu
  removes it right away.

## Output

Each recording gets its own folder, `<Transcripts>/<yyyy-MM-dd HH-mm> <title>/`:

| File | Purpose |
| --- | --- |
| `transcript.md` | Readable transcript, grouped by speaker with timestamps. Re-rendered after every segment. |
| `transcript.jsonl` | One JSON object per segment, appended and fsync'ed immediately. This is the crash-safe source of truth. |
| `transcript.json`, `transcript.srt` | Optional exports (Settings › Output). |
| `mic.wav`, `system.wav` | Raw 16 kHz mono audio, flushed every 2 s. Kept for 7 days by default (Settings › Output). |
| `session.json` | Metadata and status (`recording` / `complete`), names typed during the call, mute phases. |

If the Mac crashes mid-call, the transcript up to the last segment is already on disk.
Next time you launch, Transcriber offers to finalize that session: it transcribes
whatever audio hadn't been processed yet and writes the final files.

## How speakers are separated

- Your microphone channel is you (the label is yours to set).
- The system-audio channel is the other side. After the call, pyannote diarization
  runs over that channel and splits it into "Speaker 1", "Speaker 2", and so on when it
  hears more than one remote voice, numbered in the order they first speak. Voices the
  clustering splits off with only a few seconds of speech are merged into the closest
  real speaker; anyone who said more than a sentence or two keeps their own label, also
  in big meetings.
- Names typed for the current speaker during the call are matched to these voices: the
  voice that dominates the named stretch gets the name everywhere.
- **Remember voices** (Settings › Transcription, on by default). A voice you name in the
  pill is kept as a voice print (an embedding, no audio) in
  `~/Library/Application Support/Transcriber/voices.json` and recognised in later
  recordings. Only names you give are learned, never automatic matches, and the bar for
  a match is set high: an unknown voice stays "Speaker N" rather than getting the wrong
  name. You can forget each voice in Settings, or all at once.
- **Echo gate** (on by default). Without headphones your microphone also picks up the
  loudspeaker, so the far end would land in the transcript twice. The gate takes the
  system-audio channel as a reference, works out the delay and the echo gain, and mutes
  the mic frames that only carry the far end. Both channels are lined up on the
  recording's own sample timeline, so the gate behaves live exactly as it does in an
  offline run over `mic.wav` and `system.wav`. A text-level check then drops anything
  that slipped past. On a real 54-minute Zoom call that took out 220 of 225 echo
  segments; on a 115-minute call over MacBook speakers, a 5-minute test section went
  from 403 echo words on my side to none, with my own words intact.
- Apple's voice processing is there as an experimental alternative (off by default).

## Implementation notes

- **System audio tap on macOS 26.** A global tap (`stereoGlobalTapButExcludeProcesses`)
  is created without an error, but its aggregate device never actually starts IO. A
  mixdown tap over the explicit list of audio process objects does work, so that's what
  Transcriber uses, and it rebuilds the tap whenever the process list changes (an app
  launched mid-recording, say).
- **System audio sample rate.** The tap's buffers arrive on the output device's clock,
  which isn't always the rate the tap reports: AirPods drop to 24 kHz in call mode once
  their microphone opens. Transcriber uses the aggregate device's actual rate, follows
  rate changes, and as a safety net checks delivered frames against wall-clock time
  (logged as `measured … frames/s`). Before that, a call on AirPods recorded the far end
  at double speed and half length, which also wrecked echo removal and speaker
  separation.
- **System audio permission.** There's no public API to bring up the prompt, so the app
  calls the private `TCCAccessRequest` for `kTCCServiceAudioCapture`. That's fine for a
  personal build, and it's also why this can't go on the App Store.

## Project layout

```
Sources/Transcriber
├── App/            entry point, AppDelegate, AppState, AppSettings
├── Audio/          Core Audio devices, microphone capture, system audio tap, resampler, WAV writer
├── Transcription/  ModelManager, FluidAudio engine, VAD segmenter, transcription queue, diarizer
├── Storage/        SessionStore (JSONL/MD), exporters, crash recovery, recording history, voice library
├── Recording/      RecordingCoordinator (orchestration), RecordingFinalizer
├── System/         hotkey, power assertion, launch at login, call detection, consent notice
└── UI/             status item + pill/waveform, floating bar, settings window
```

## Hand transcripts to an AI tool

Settings › AI lets you point at a website (there are presets for Claude, ChatGPT, and
Perplexity, or any URL with a `{prompt}` placeholder) or a Mac app, and edit the prompt
template (`{transcript}` gets replaced by the transcript). "Save & Open in …" in the
title dialog, and "Open Last Transcript in …" in the menu, then open that tool with the
prompt already filled in, and you only press Enter. Short prompts ride along in the URL;
a real transcript is far too long for that, so the text goes onto the clipboard and
pastes itself (that needs the Accessibility permission, which macOS asks for once). It
only pastes while the AI app or browser is still in front; if you've switched to
another app in the meantime, the text stays on the clipboard and Transcriber tells you
to paste it yourself, so a transcript never lands in the wrong window. If
you've renamed or re-signed the app and the grant won't take, an entry left over from
the old signature can hang around, and the dialog keeps popping up even though the
toggle looks on. Turn Transcriber off and back on under System Settings › Privacy &
Security › Accessibility (or run `tccutil reset Accessibility com.moritzkrause.anyrecord`)
to rebuild it. When the paste fails for that reason, the "Transcript copied" dialog says so and
has a button that opens the Accessibility settings.

## App icon

`Resources/AppIcon.icns` comes from `scripts/make-icon.swift`, a CoreGraphics rendering
of the design I settled on (the floating bar with two lines of transcript):

```sh
swift scripts/make-icon.swift Resources/AppIcon-1024.png 1024
# then build the iconset / icns with sips + iconutil (see git history of this file)
```

## Versions and updates

- The version lives in `Resources/Info.plist` (`CFBundleShortVersionString`), and
  `bundle.sh` stamps the build number (the commit count) and the git hash into the built
  app.
- `./scripts/release.sh 0.2.0 "notes"` bumps the version, commits, tags `v0.2.0`,
  builds, zips, and publishes a GitHub release with the zip attached.
- A version with a suffix, say `./scripts/release.sh 0.3.0-beta.1`, goes out as a GitHub
  pre-release. The normal update check skips pre-releases; anyone who switches on
  "Include pre-releases" in Settings › General gets offered them. A later `0.3.0` counts
  as newer than any `0.3.0-…` pre-release.
- Inside the app, **Check for Updates…** (right-click menu or Settings › General)
  compares the running version against the latest GitHub release and can download,
  install, and relaunch it. It also checks once a day on its own. It talks to the public
  GitHub API with no token, so it works for everyone as long as the repository is public.
- The installer only accepts an update signed by the same identity as the running app
  (it checks the designated requirement through the Security framework before it swaps
  anything). So an ad-hoc signed build can't update itself; sign with a stable identity
  (see "Code signing and permissions"). The bundle runs with the hardened runtime.
- Worth knowing: an app built on a different Mac carries a different signature, so macOS
  asks for the microphone and system-audio permissions again after that kind of update.

## Legal

In a lot of places, recording a conversation without consent is illegal (in Germany,
for instance, § 201 StGB). Tell the people on the call before you start.
