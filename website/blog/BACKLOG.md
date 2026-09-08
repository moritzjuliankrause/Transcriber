# Blog backlog

Ordered list of pieces to write, top first. The daily writer routine takes the first entry with
`status: todo`, writes it as a draft, sets it to `status: drafted` with the date, commits, pushes.
Moritz reviews it in Slack like every other post. Keywords here are hypotheses; once DataForSEO and
Search Console are wired up, the keyword routine takes over topic selection and this list becomes
the fallback for days without a verified keyword.

Types: `article` (informational, 700 to 1,200 words), `comparison` (honest table, 800 to 1,400 words,
competitor facts verified live with WebFetch during the run, prices dated), `guide` (per-app how-to).
Facts about Transcriber: repo README only. Slugs are final URLs.

---

- slug: record-teams-meeting-mac-transcript
  type: guide
  title: How to record a Microsoft Teams meeting on a Mac and get a transcript
  keyword: record teams meeting mac
  angle: Teams is the corporate default and its own recording depends on admin policy; local recording works regardless. Same structure as the Zoom post, Teams-specific quirks (recording policy, Teams in the browser vs the app).
  volume: 10 (US, 2026-09)
  kd: 1
  status: drafted 2026-09-08



- slug: record-facetime-call-mac
  type: guide
  title: How to record a FaceTime call, with both sides, on a Mac
  keyword: how to record a facetime call
  angle: FaceTime has no recording feature at all. The consent part matters more here because FaceTime calls are private by nature.
  volume: 1900 (US, 2026-09; "record facetime call mac" itself has 0)
  kd: 0
  status: todo



- slug: record-google-meet-mac-transcript
  type: guide
  title: How to record a Google Meet call on a Mac with a transcript
  keyword: record google meet mac
  angle: Meet runs in a browser tab, so the system audio tap catches it like any other tab. Meet's own recording needs a Workspace plan; local recording does not.
  volume: 10 (US, 2026-09)
  kd: 0
  status: todo



- slug: speaker-diarization-explained
  type: article
  title: What speaker diarization is and why two audio channels make it easy
  keyword: speaker diarization
  angle: Education piece. Diarization in general, then why a mic channel plus a system channel already solves half of it.
  volume: 880 (US, 2026-09)
  kd: 23
  status: todo



- slug: record-system-audio-mac
  type: article
  title: How to record system audio on a Mac without a virtual driver
  keyword: record system audio mac
  angle: Top-of-funnel evergreen. The macOS 14.2 audio tap explained for normal people, the old BlackHole/Soundflower workaround and why it broke, and Transcriber as one app that uses the tap. Honest: for pure audio capture without transcript, other tools are fine too.
  volume: 390 (US, 2026-09)
  kd: 0
  status: todo



- slug: otter-ai-alternative-mac-offline
  type: comparison
  title: Otter.ai alternative for Mac that works offline
  keyword: otter ai alternative
  angle: Otter does far more (shared workspace, bot, search, mobile). Say so. The difference is where the audio goes and whether a bot joins. Verify Otter's current plans and prices live and date them.
  volume: 390 (US, 2026-09)
  kd: 0
  status: todo



- slug: granola-vs-transcriber
  type: comparison
  title: Granola vs Transcriber for meeting notes on a Mac
  keyword: granola alternative
  angle: Granola is a popular Mac note-taker without a bot as well. Verify live how it captures audio and where transcription happens; be precise about the difference, and if Granola is the better fit for note-taking, say so.
  volume: 320 (US, 2026-09)
  kd: 0
  status: todo


- slug: fireflies-alternative-without-bot
  type: comparison
  title: Fireflies alternative that doesn't send a bot into your meetings
  keyword: fireflies alternative
  angle: Same pattern as Otter. Fireflies' strength is CRM integrations and team search; Transcriber has none of that. Verify live.
  volume: 90 (US, 2026-09)
  kd: 0
  status: todo



- slug: macwhisper-vs-transcriber
  type: comparison
  title: MacWhisper vs Transcriber, two local tools that do different jobs
  keyword: macwhisper alternative
  angle: Closest local neighbour. MacWhisper is a file transcription app with many features and a paid tier; Transcriber is a live two-channel call recorder. Recommend MacWhisper for files, Transcriber for calls. Verify MacWhisper features and price live.
  volume: 30 (US, 2026-09)
  kd: 0
  status: todo



- slug: record-podcast-interview-remotely-mac
  type: article
  title: How to record a remote podcast interview on a Mac with a transcript
  keyword: record podcast interview remotely
  angle: Neighbouring audience. Transcriber captures both sides as separate WAVs, which is what podcasters want. Honest: no per-guest studio tracks like Riverside.
  volume: 10 (US, 2026-09)
  kd: 0
  status: todo



- slug: is-it-legal-to-record-a-call
  type: article
  title: Is it legal to record a call? Germany, EU, US and UK in plain words
  keyword: is it legal to record a call
  angle: Sourced per country (§ 201 StGB, one-party vs two-party US states, UK, Austria, Switzerland), links to the law texts, no legal advice claim. Transcriber mentioned once: it records locally, consent is still yours.
  volume: 10 (US, 2026-09)
  kd: 32
  status: todo



- slug: summarize-meeting-transcript-claude-chatgpt
  type: article
  title: How to summarize a meeting transcript with Claude or ChatGPT
  keyword: summarize meeting transcript ai
  angle: Includes the app's default prompt template as a copyable block (it is in the README section on AI hand-off). Shows the Save & Open flow. Honest about hallucinated action items and the need to read the transcript.
  volume: 10 (US, 2026-09)
  kd: 40
  status: todo



- slug: record-whatsapp-call-mac
  type: guide
  title: How to record a WhatsApp call on a Mac
  keyword: record whatsapp call mac
  angle: WhatsApp desktop plays audio through the Mac like any app, so it works; no other tool covers this well. Consent section up front.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: apple-call-recording-vs-transcriber
  type: comparison
  title: Apple's built-in call recording vs Transcriber
  keyword: mac call recording built in
  angle: Apple's own recording and transcription in FaceTime and Phone is the default competitor. Verify live which macOS versions and apps Apple covers today, and what it does not (third-party apps like Zoom, Teams, browser calls).
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: local-vs-cloud-transcription
  type: article
  title: Local vs cloud transcription: what you gain and what you give up
  keyword: local transcription vs cloud
  angle: Privacy, cost, speed, accuracy, features. Cloud wins on shared workspaces and speaker names; local wins on privacy and cost. No accuracy percentages, none are in the README.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: transcript-file-formats-markdown-jsonl-srt
  type: article
  title: What's inside a Transcriber recording folder: Markdown, JSONL, SRT, WAV
  keyword: transcript file formats
  angle: Reference page for developers and Obsidian users. Every file explained from the README output table, crash-safe JSONL story, how to import into Obsidian or a script.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: fix-echo-duplicate-lines-call-transcript
  type: article
  title: Why call transcripts show the other person twice, and how the echo gate fixes it
  keyword: echo in call transcript
  angle: The echo gate explained, the 220 of 225 figure from the README, headphones as the cleaner setup.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: transcribe-youtube-video-locally-mac
  type: article
  title: How to transcribe a YouTube video or webinar on a Mac, offline
  keyword: transcribe youtube video mac
  angle: "Anything that plays audio" is in the README. Also honest: for long videos a file-based tool may be more convenient.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: meeting-transcripts-gdpr-freelancers
  type: article
  title: Meeting transcripts and the GDPR: a practical guide for freelancers and small teams
  keyword: meeting transcript gdpr
  angle: Processor question disappears when nothing leaves the Mac; consent and legal basis remain. Sourced, no legal advice claim.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: transcriber-troubleshooting-permissions-audio
  type: guide
  title: Transcriber troubleshooting: permissions, missing system audio, echo
  keyword: transcriber not recording system audio
  angle: From the README: permission resets after rebuilds with a different signature, the macOS 26 global tap note, the capture test command, the log file location.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: transcriber-system-requirements
  type: guide
  title: What Mac you need for Transcriber
  keyword: transcriber system requirements
  angle: macOS 14.2, Apple Silicon recommended, the 1 GB model download, disk space, what Intel means in practice (README only says recommended, do not invent numbers).
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: live-transcript-during-call-accessibility
  type: article
  title: A live transcript during your calls, and who it helps
  keyword: live transcript during call mac
  angle: The floating bar as an accessibility aid for hard-of-hearing users and for noisy rooms. No medical claims.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: crash-safe-transcripts-jsonl
  type: article
  title: Why a transcript should survive a crash, and how Transcriber does it
  keyword: crash safe transcript
  angle: Short technical story from the README: JSONL appended and fsync'ed per segment, recovery on next launch.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo



- slug: best-free-call-transcription-apps-mac
  type: comparison
  title: Free call transcription apps for Mac in 2026, compared honestly
  keyword: free call transcription app mac
  angle: Roundup including competitors fairly (verify each live: Apple built-in, MacWhisper free tier, Otter free tier, Krisp, Granola). Transcriber is one row, not the winner by default.
  volume: 0 (US, 2026-09)
  kd: 0
  status: todo
