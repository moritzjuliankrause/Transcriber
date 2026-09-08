# Editor learnings

Rules derived from the difference between the writer's drafts and the versions Moritz approved.
Source: `blog-reviews/<slug>/`. The writer reads this file before every post, after `VOICE.md` and
`writing-rules.md`, and it wins over both where they conflict, because it reflects real corrections.

Format per rule:

```
## <short rule>
- Since: <date>, from: <slug>[, <slug>…]
- Before: <what the draft did, one line or a short quote>
- After: <what Moritz made of it>
- Why (assumed): <one sentence>
- Apply: <how to follow it in the next post>
```

Confirmations (approved without edits) go in the log at the bottom, they tell us which rules are stable.

---

## A short direct aside to the reader is welcome, and a single "!" is fine
- Since: 2026-09-08, from: how-transcriber-works, transcriber-privacy-what-leaves-your-mac
- Before: "...you rename them if you need to." / "...the part the app can't take off your hands: telling people they are being recorded."
- After: "...you rename them if you need to (there is an experimental feature which could figure out the names live during the call, but yeah, experimental)." / "...the part the app can't do for you: telling people they are being recorded (and you better tell them!)."
- Why (assumed): Moritz writes like a colleague at the desk, so a small human aside is his voice, not a pitch. The WRITING.md bans are on exclamation-mark chains and startup tone, not on one "!" or a personal aside.
- Apply: Where a sentence invites it, one short parenthetical or trailing aside in Moritz's voice reads well. A single exclamation mark is allowed; chains and hype stay out. At most one such aside per section, never as a sell.

## Don't stamp the material as boring, and drop stiff "to prove it" demos
- Since: 2026-09-08, from: transcriber-privacy-what-leaves-your-mac
- Before: "Two things, and both are boring." / "...runs without the network, and you can pull the Ethernet cable to prove it."
- After: "Two things." / "...runs without the network (try transcribing offline. It'll work)."
- Why (assumed): Calling the content boring is the writer judging it for the reader, and "pull the Ethernet cable to prove it" is theatrical. Moritz states the fact plainly, or turns the check into a light, direct suggestion.
- Apply: Never label content boring, dull, or unremarkable. For a "you can verify this yourself" point, give the plain instruction, not a staged demonstration.

## The experimental live speaker-naming feature may be named, but only hedged as experimental
- Since: 2026-09-08, from: how-transcriber-works
- Before: draft followed WRITING.md and never mentioned live naming; far-end speakers were labels only.
- After: Moritz added "(there is an experimental feature which could figure out the names live during the call, but yeah, experimental)".
- Why (assumed): The feature is real to the developer but is not in the README and is not reliable, so Moritz will only mention it with a clear "experimental" hedge. This overrides the WRITING.md blanket "no name guessing" ban for this one hedged case.
- Apply: You may note the experimental live-naming feature exactly as a hedged aside ("experimental", not promised). Do not present it as working, do not attach accuracy claims, and do not treat this as licence to invent any other feature that is absent from the README.

## Log
- 2026-09-08: file created, no approved posts with edits yet.
- 2026-09-08, how-transcriber-works: one-off edits kept out of the rules above. WhatsApp was added to the example app list ("Zoom, Teams, WhatsApp or a browser"); it is in the README app list, so prefer to include the everyday apps the README names (Zoom, Teams, Meet, WhatsApp) when giving examples. The code-signing / personal-certificate paragraph was cut from "Where is it rough?"; Moritz does not treat the signing setup as a user-facing rough edge, so leave signing detail out of a limitations list unless a post is specifically about it.
- 2026-09-08, transcriber-privacy-what-leaves-your-mac: learned; edits captured in the rules above.
