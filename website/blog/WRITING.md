# Writing rules for the Transcriber blog

The short version of the voice and anti-slop rules, kept in the repo so a cloud session can read them.
Order of authority: `EDITOR-LEARNINGS.md` (what Moritz actually changed) beats this file, this file
beats habit. Facts about Transcriber come from the repo root `README.md` only.

## Who speaks
Moritz Krause, the developer of Transcriber, writing like a colleague explaining something at a desk.
First person is fine when it is about experience ("the way I work"), facts stay factual. No other
role is ever claimed.

## Attitude
- Honest before convincing. If a cloud tool or a bot does something better, say so plainly. If
  Transcriber can't do something, say so. Every post names at least one real limit.
- Transcriber is described as a way of working, not the solution to everything. No pushing, the reader
  decides. Brand name at most three times in the body; the closing paragraph is rendered by the build.
- The reader is taken seriously: no rhetorical question openers, no "you know the feeling", no
  dramatising the problem. Someone who searched for this knows what they want.

## Form
- The first paragraph answers the title directly in two to four sentences, self-contained.
- H2s are phrased as questions where that sounds natural. The first sentence after each H2 answers it.
- 700 to 1,200 words for articles, 800 to 1,400 for comparisons. Clarity over length.
- Prose by default. At most two or three lists per post, three to six short items each, never two
  lists in a row, never a bulleted ending. Tables only for a real two-dimensional comparison.
- Contractions (it's, don't, can't). Vary sentence length. Commas and periods outside quotes.
- FAQ: four to eight real questions in the frontmatter, answered in one to three sentences each.
- Every number, date, price or version is either in the README or verified live during the run.
  Otherwise it is cut. "220 of 225 echo segments on a 54-minute Zoom call" is in the README; a
  claimed accuracy percentage is not.
- Every post links to the landing page and to at least one sibling post that exists in the sitemap.

## Hard bans
- No en or em dashes anywhere, the build rejects the file. Use " - " with spaces, a comma, or a period.
- No "Not X. It's Y." pivots, no "No X. No Y. Just Z." triplets, no three-adjective triads.
- No "here's the thing", "let's dive in", "it's worth noting", "in conclusion", "at the end of the
  day", "in today's world", "when it comes to", "that being said", "a testament to", "the hard part".
- No: delve, tapestry, landscape, robust, seamless, cutting-edge, groundbreaking, transformative,
  unprecedented, pivotal, leverage, harness, unlock, unleash, navigate, foster, elevate, embark,
  furthermore, moreover, additionally, consequently, notably, compelling, innovative, dynamic,
  utilize, comprehensive, paramount, meticulous, game-changer, streamline, scalable, crucial,
  remarkable, profound, multifaceted, nuanced, facilitate, endeavor, resonate, bolster, underscore,
  illuminate, empower, supercharge, skyrocket, cultivate.
- No marketing words about the product: revolutionary, AI-powered as a selling point, next
  generation, game changer, powerful, intelligent, smart, best. Say what the software does instead.
- No emojis in the body, no exclamation mark chains, no startup pitch tone.
- No claims about features that are not in the README (no call detection, no name guessing, no
  accuracy figures, no App Store, no Windows).

## Comparisons
A table with real differences, each row verifiable, each price checked live. If the other tool clearly
does more, write a sentence like "X does a lot more than Transcriber. If you need Y, use X." Then the
honest point: how the way of working differs and for whom that matters. Never "Transcriber is the
better choice", never invent or inflate the other tool's weaknesses.

## German (once the DE blog exists)
Du. Adaptation with its own examples and FAQ, not a translation. Technical terms stay English where
people say them in English (Transcript, Call, Diarization). No "Lösung", "Erlebnis", "Mehrwert",
"nahtlos", "ganzheitlich", "revolutionär", "spannend" as filler, "in der heutigen Zeit", "es ist
wichtig zu beachten", "tauchen wir ein".
