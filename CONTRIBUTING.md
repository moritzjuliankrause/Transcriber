# Contributing

Transcriber is a tool I built for myself and then made public because it turned
out useful. It's not a company project and there's no roadmap I'm holding anyone
to. That shapes how this works: I read everything that comes in, I'm happy when
people find it useful, and I don't promise to merge every change or ship every
idea. No hard feelings either way.

If that's fine with you, here's how to help.

## Found a bug or something odd

Open an issue (there's a short template) or, if you'd rather not use GitHub,
email me at moritz@moritz-krause.com. The one thing that saves us both time is a
line from the log. The app writes `~/Library/Logs/Transcriber.log`, and it
records the device, audio formats, the tap and echo-gate stats every 30 seconds,
and any restarts. Paste the part around the moment it went wrong, and tell me
your macOS version and Mac (Apple Silicon or Intel).

For an audio-capture problem, the built-in test usually shows what's happening:

```sh
open -a /Applications/Transcriber.app --args --capture-test 8 --log /tmp/capture.log
sleep 25; cat /tmp/capture.log
```

It prints permission state, callback counts and peak levels for the microphone
and the system-audio tap. That output in the issue is gold.

## Have an idea

Open an issue and describe the situation you're actually in, not just the
feature. I care more about the problem than the proposed solution, and the honest
version ("I'm on a lot of Teams calls and X keeps happening") tells me more than a
spec. It might already be on my own list, it might not fit how the app works, and
I'll say so plainly.

## Want to send code

Great, but read this first so a PR doesn't sit in limbo. Because this is a
personal project I'm careful about what goes into the codebase, so:

- Open an issue before a large change and let's agree it's a direction I'd merge.
  A small fix (a crash, a typo, an obvious bug) you can just send.
- Keep the pull request focused on one thing. One fix or one feature per PR.
- Match the surrounding Swift. No new dependencies without a reason we've talked
  about first.
- Build it and run it before you send it. There's no CI gate that will catch
  things for you.

```sh
./scripts/bundle.sh          # release build + Transcriber.app
open dist/Transcriber.app
```

Everything else about building, permissions and the project layout is in the
[README](README.md).

## What this project is not

It's a menu bar app that records and transcribes calls locally. It's not trying
to be a platform, a service, or the most feature-complete transcriber out there.
If you need something it deliberately doesn't do, another tool may fit you better,
and that's genuinely fine.

By contributing you agree that your contribution is licensed under the same
[MIT License](LICENSE) as the rest of the project.
