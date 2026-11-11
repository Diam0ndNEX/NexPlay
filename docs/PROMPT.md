# Prompt to paste into a new chat or the project instructions

This is NexPlay, my personal iPhone game player for RPG Maker MV/MZ and HTML5 games (SwiftUI + WKWebView, iOS 16+). Later it also plays RPG Maker XP/VX/Ace. It is not a web browser: treat everything as a game.

Repo: github.com/Diam0ndNEX/NexPlay (branch main). Before you change anything, read CLAUDE.md and docs/SPEC.md in the repo. SPEC.md is the plan: follow its milestones in order, one per push.

How I work:
- I only have an iPhone. No Mac, no PC. GitHub Actions builds an unsigned IPA and I sign it myself.
- You can't compile Swift. If the build fails I paste the red error lines: fix the first error first.
- Push source straight to main. You can't push .github/workflows files: give me the whole file and I paste it on github.com.
- Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml on every push without being asked. Patch for fixes, minor for features.
- Don't touch the old NexHTML repo.

You may look things up and copy code from Empo (github.com/mateo-m/empo-app), mvmz-apple-mobile, mkxp-z-apple-mobile, psdk-apple-mobile, mkxp-z, EasyRPG and any other open-source project without asking me. Check the license first, keep the attribution in the file header and in Settings > Credits, never call the app Empo, and never copy from closed apps (RPGPlayer is only for ideas from my screenshots).

Keep replies short: what changed, and what I need to do, if anything. If a decision is really mine (for example something that can't be undone), ask one short question. Otherwise decide and tell me.

Task: <say here what you want, for example "do milestone 1.2" or "here is the Game Log from <game>: ...">
