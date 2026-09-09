# Transcriber — project instructions

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
fits. Keep the README's calm, factual tone and its existing depth — describe what the
user sees and does, not the implementation detail.

Skip the README only for pure bug fixes, refactors, or internal changes with no
user- or developer-visible effect. When in doubt, add it. If a change is worth a
CHANGELOG entry, it is almost certainly worth a README check.
