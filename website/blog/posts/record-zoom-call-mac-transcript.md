---
title: How to record a Zoom call on a Mac and get a transcript
description: Record a Zoom call on your Mac, with both sides of the conversation, and turn it into a transcript without sending the audio anywhere.
date: 2026-09-08
author: Moritz Krause
keyword: record zoom call mac
keywords: [record zoom call mac, zoom call transcript, transcribe zoom call, system audio mac]
draft: false
faq:
  - q: Does Zoom have to be set to record for this to work?
    a: No. Transcriber listens to what your Mac plays and what your microphone hears, so it doesn't matter whether Zoom's own recording is on, off, or locked by the host.
  - q: Will the other person be transcribed as well?
    a: Yes. The far end comes in through your Mac's audio output and is captured as its own channel, so their words land in the transcript with a separate speaker label.
  - q: Does any audio leave my Mac?
    a: No. Transcription runs on your machine with a downloaded model. The only network access is the one-time download of that model and the update check against GitHub.
  - q: Which macOS version do I need?
    a: macOS 14.2 or newer, because that's where Apple added the audio tap that makes recording another app's sound possible. An Apple Silicon Mac is recommended.
  - q: Is it legal to record a call?
    a: That depends on where you and the other people are. In many places, including Germany, recording without consent is a crime. Tell everyone before you press record.
---

Recording a Zoom call on a Mac means capturing two things at once: your own microphone and the sound the other people make, which comes out of Zoom as system audio. Zoom's built-in recording does that, but only if the host allows it, and the transcript it produces lives in Zoom's cloud. Transcriber does the same job locally: it records both channels into a folder on your Mac and writes the transcript while you're still talking.

This post walks through how that works, what you get at the end, and where the approach has limits.

## Why doesn't screen recording pick up the other person?

Because macOS treats the sound another app plays as that app's business. QuickTime and the built-in screen recorder capture your microphone without fuss, but the far end of a call is audio that Zoom sends to your speakers, and until recently there was no clean way to tap into it. People worked around this with virtual audio drivers, which is a whole afternoon of fiddling and breaks with the next macOS update.

Since macOS 14.2, Apple offers an audio tap that lets an app listen to what other apps play, after you give it permission once. Transcriber uses that tap for the system side and your normal microphone for your side. Two channels, recorded in parallel, which also happens to be exactly what you need to tell speakers apart later.

## How do you record the call?

You click the dot in the menu bar, or press the global shortcut ⌃⌥⌘R, and that's the whole procedure. The dot turns red and grows into a small pill with a waveform and a timer. A floating bar below the menu bar shows the transcript as it forms, so you can see straight away whether the microphone is picking you up and whether the other side is coming through.

The first time you do this, macOS asks for two permissions: Microphone and System Audio Recording. Both are needed, and both are remembered as long as the app keeps the same code signature. The first recording also downloads the transcription models, roughly a gigabyte, which happens once.

When the call is over you click the dot again. Transcriber asks whether you want to stop, finishes the transcription, runs speaker separation over the far end, and asks for a title. That title becomes the folder name.

## What does the transcript look like?

Each recording is a folder named after the date and the title you gave it. Inside is a readable Markdown file grouped by speaker with timestamps, and next to it a line-by-line JSON file that is written and flushed after every segment. That second file is the important one: if your Mac crashes in the middle of a two-hour call, everything up to the last segment is already on disk, and Transcriber offers to finish the recording on the next launch.

Your own channel is labelled with your name, and the other side is labelled by speaker. If three people were talking on the far end, the diarization step after the call splits them into Speaker 1, Speaker 2 and Speaker 3. You can also keep the raw audio files if you want, and export SRT or JSON if another tool needs them.

## What about echo when you don't wear headphones?

Without headphones your microphone hears the loudspeaker, so the far end would show up twice: once from the system channel and once, slightly delayed and muffled, from your mic. Transcriber has an echo gate for this. It uses the system channel as a reference, estimates the delay and how loud the echo is, and mutes microphone frames that only contain the far end. A text-level check afterwards drops any duplicate that slipped through. On a real 54-minute Zoom call this removed 220 of 225 echo segments.

Headphones are still the cleaner setup. The gate is there for the calls where you forgot them.

## Where does this approach fall short?

Transcriber is a recorder with a transcript, not a meeting assistant. It doesn't join the call as a participant, so nobody sees a bot in the attendee list, but it also can't record a meeting you're not in. It runs on your Mac, which means it doesn't work from a phone or a Windows laptop. And the transcription model, while good, is a model: names, product codes and heavy accents will need a read-through.

If you need shared meeting notes that a whole team can search, a cloud tool is the better fit. If you want a private, complete transcript of the calls you're personally on, without uploading a minute of audio, this is the way I work.

## How do you hand the transcript to an AI afterwards?

Settings lets you pick a website like Claude or ChatGPT, or a Mac app, and edit a prompt template. When the title dialog appears after a call, one of the buttons is "Save & Open in Claude". Transcriber puts the transcript on the clipboard, opens the tool with your prompt, and pastes. You press Enter and ask for a summary, action items, or whatever you need.
