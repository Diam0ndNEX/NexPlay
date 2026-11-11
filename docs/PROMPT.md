# Prompt for the 2.0.0 one-shot build

Paste the block below into a new chat (Opus) in the NexPlay project.

```
This is NexPlay, my personal iPhone game player for RPG Maker (SwiftUI + WKWebView, iOS 16+). Repo: github.com/Diam0ndNEX/NexPlay, branch main.

Task: build NexPlay 2.0.0 in one run. First read CLAUDE.md, docs/SPEC.md and docs/RESEARCH.md in the repo completely. SPEC.md is the full plan: do Parts A to H in order, one commit per part pushed straight to main, without stopping to ask me. Every item is tagged P0/P1/P2: finish all P0 of every part first, then P1, then P2 if there is room, and list anything you skip in CLAUDE.md under "Not built". Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml on every push exactly as SPEC.md says (final: 2.0.0, build 13).

How I work: I only have an iPhone. No Mac, no PC. GitHub Actions builds an unsigned IPA on every push and I sign it myself. You can't compile Swift, so write boring, explicit code that works on iOS 16 and re-read every file you changed for compile errors before each push (SPEC.md section 5). If the build fails later, I will paste the red lines and you fix the first error first.

You can't push .github/workflows files. If a part needs a workflow change, put the full file in docs/ as SPEC.md says and print it in your final message so I can paste it on github.com.

Research is part of the job. The reference apps have more than the spec lists: before each part, re-read the matching Empo files and docs (github.com/mateo-m/empo-app and its cores mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile), search GitHub and the web for how other projects solved the same problem, and copy or adapt what fits without asking me. Check the license, keep attribution in file headers and in Settings > Credits, never call the app Empo, never copy closed apps (RPGPlayer, ArkRPG and others are for ideas only). Leave the old NexHTML repo untouched.

Don't ask me questions unless a decision can't be undone and could go either way. Decide with the defaults in SPEC.md and write the decision in CLAUDE.md. At the end, send a short message: what was built per part, what you skipped and why, the workflow file if it changed, and the device test checklist from SPEC.md section 8.
```
