# Security

Transcriber records your calls and transcribes them, so I take this seriously
even though it's a small project. Here's how it handles your data and how to tell
me if something's wrong.

## What the app touches

- **Audio.** Your microphone and the system-audio output are captured only while
  a recording is running. Everything is processed on your Mac.
- **Network.** The only outbound connection is the one-time model download (about
  1 GB, Parakeet plus the VAD and diarization models) and the daily update check
  against the public GitHub API. There is no analytics, no account, no telemetry.
  Your audio and transcripts never leave the machine.
- **Files.** Recordings and transcripts are written to the transcripts folder you
  pick. The app also writes a log to `~/Library/Logs/Transcriber.log` (device and
  format info and echo-gate stats, no transcript text).
- **Clipboard and Accessibility.** The "open in an AI tool" feature copies the
  transcript to the clipboard and, with your permission, pastes it into the app
  or website you chose. That permission is only used for that paste.
- One note on macOS internals: there's no public API to trigger the system-audio
  permission prompt, so the app calls a private one (`TCCAccessRequest` for
  `kTCCServiceAudioCapture`). That's fine for a personal build and is the reason
  it isn't distributed through the App Store.

## Reporting something

If you've found a security or privacy problem, please don't open a public issue
for it. Email me directly at **moritz@moritz-krause.com** and give me a chance to
fix it first. Include what you did, what happened, your macOS version and the app
version (Settings › General shows it).

I'll reply as soon as I can. This is a side project, so I can't promise a
same-day turnaround, but a genuine security issue jumps the queue. Once it's
fixed I'll credit you in the release notes if you'd like, or keep you out of them
if you'd rather.

## Supported versions

I fix issues in the latest release. If you're on an older build, please update
first (right-click menu › Check for Updates…) and see whether the problem is
still there.
