# Changelog

Shown in the app under Settings → General → Show Changes. `scripts/release.sh` adds a
section for every release; keep entries short, one bullet per user-visible change.

## 0.3.6 (2026-09-08)
- System audio capture now works when the output device is a USB audio interface with its own inputs (e.g. Focusrite Scarlett): the tap's stream is read instead of the interface's silent input channels.

## 0.3.5 (2026-09-08)
- What's New window (Settings → General → Show Changes) listing every version and its changes

## 0.3.4 (2026-09-08)
- About section in Settings → General with links to the GitHub repository, issue reporting and GitHub Sponsors

## 0.3.3 (2026-09-08)
- Fixed a recording start failure (Core Audio error -10868) after Apple voice processing falls back to plain capture
- Removed the dark rectangle that could linger behind the floating bar after the save prompt

## 0.3.2 (2026-09-08)
- Copy Prompt no longer resizes the template field and shows a short "Prompt copied" pill

## 0.3.1 (2026-09-08)
- Copy Prompt button below the prompt template in Settings → AI

## 0.3.0 (2026-09-08)
- Redesigned Settings window with light and dark mode; new Theme setting under General
- The recording title is entered directly in the floating bar, which morphs into a save prompt after stopping
- All floating bar buttons are pill-shaped

## 0.2.4 (2026-09-07)
- Verified updates: a downloaded update must be signed by the same identity as the installed app
- Private clipboard hand-off: transcripts handed to the AI tool are marked concealed and cleared after pasting
- Hardened runtime; logs no longer contain transcript fragments or guessed speaker names
- Relaunch after an update no longer goes through a shell

## 0.2.3 (2026-09-07)
- First launch offers to download the speech models right away
- Configurable automatic update check: never, every launch, daily, weekly or monthly

## 0.2.2 (2026-09-07)
- New update window with app icon, versions, full release notes and Install and Relaunch

## 0.2.1 (2026-09-07)
- The Name-this-recording dialog no longer gets stuck when a recording starts while the previous one is still saving
- The floating bar no longer shows a faint rectangular backing on some Macs
- Menu bar icon is white on a dark menu bar; quitting during a recording no longer hangs

## 0.2.0 (2026-09-07)
- The app is now called Transcriber (formerly AnyRecord); existing installs keep updating
- Live transcript bar: calm, stable text, no jumping lines, speaker names only on speaker change, echo taken back
- The bar morphs between a compact pill, the full transcript and the stop confirmation
- Models are loaded at launch, so recording starts immediately
- Menu bar glyph pulses red while recording; stop confirmation instead of stopping on a stray click
- AI hand-off attaches transcript.md as a file; new default prompt with summary, to-dos and open questions
- Open Last Transcript reveals the file in Finder with Quick Look
- Experimental guessing of remote speakers' names from the conversation
- Options for Dock icon and app-wide sound effects

## 0.1.1 (2026-09-07)
- First tagged release: local call transcription with echo gate, pause button and in-app updates
