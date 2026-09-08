# Site config: gettranscriber.com

- Site: https://gettranscriber.com, blog at /blog/, feed at /blog/feed.xml, sitemap index at /sitemap.xml.
- Product in one sentence: Transcriber is a free, open source macOS menu bar app that records calls from any app (microphone plus system audio), transcribes them locally, separates speakers and saves the transcript live to a folder. Nothing joins the call and no audio leaves the Mac.
- Author and role: Moritz Krause, developer of Transcriber. The only role ever claimed.
- Language now: English, market US (`--loc 2840`) with UK as secondary check. German comes later as adaptation (Du), not translation.
- Download: https://gettranscriber.com/download (redirects to the newest GitHub release asset). Repo: https://github.com/moritzjuliankrause/Transcriber.

## Audience, in priority
1. People who take calls for a living on a Mac and want their own record: freelancers, consultants, founders, sales, recruiters, coaches.
2. Privacy-minded users and small teams under GDPR who refuse cloud note-takers and meeting bots.
3. Developers and tinkerers who want transcripts as files (Markdown, JSONL, SRT) for Obsidian, scripts, or AI tools.

## Allowed lanes (seeds for DataForSEO)
1. Recording and transcribing calls on a Mac, per app: Zoom, Teams, Google Meet, FaceTime, WhatsApp, Slack huddles, Discord, Webex, browser calls. Seeds: "record zoom call mac", "record teams meeting mac", "transcribe google meet", "record facetime call".
2. Meeting notes without a bot, local or offline transcription, privacy of meeting transcripts, GDPR. Seeds: "meeting transcription without bot", "offline transcription mac", "local transcription", "meeting transcript privacy".
3. What to do with a transcript: summaries with Claude or ChatGPT, action items, subtitles (SRT), archives in Obsidian. Seeds: "summarize meeting transcript", "transcript to srt", "meeting notes obsidian".
4. Comparisons and alternatives: "<tool> alternative", "<tool> vs", "best call transcription app mac", "free transcription app mac". Honest comparison tone from WRITING.md, competitor facts verified live and dated.
5. Technical background people search for: system audio recording on macOS, speaker diarization, Parakeet vs Whisper, echo in call recordings.

## Forbidden lanes
- Anything Transcriber cannot do or is not in the README: Windows, iOS, cloud sync, team workspaces, recording meetings you are not in, accuracy percentages, App Store.
- Surveillance, covert recording, spying on partners or employees, recording without consent. Legal topics only as "how to do it legally".
- Generic productivity or AI content without the call-recording core.
- Anything without verified volume.

## Facts allowed in posts
Only what the repo README states. Notable: macOS 14.2 or newer, Apple Silicon recommended; two permissions; model download about 1 GB (Parakeet TDT v3, Silero VAD, pyannote); only network access is the model download and the GitHub update check; speaker separation by channel plus diarization on the remote channel; echo gate removed 220 of 225 echo segments on a 54-minute Zoom call; outputs transcript.md, transcript.jsonl (crash-safe), optional JSON, SRT, WAV; global shortcut Control-Option-Command-R; AI hand-off to Claude, ChatGPT, Perplexity or any app with a prompt template; recording without consent is illegal in many places (§ 201 StGB in Germany).

## Brand and CTA
Transcriber named at most three times in the body. The build renders the closing paragraph and the AI disclaimer; never write a sales ending. Link the landing page once and at least one sibling post.
