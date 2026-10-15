# Public readiness audit

Audit of this repository before it is made public (2026-10-15, branch
`phase-1`). Each check below says what was looked at, what was found and what
was changed. Decisions that belong to the maintainer come first. Commit
hashes are the ones before the history rewrite.

## Open decisions

1. **Old file contents still carry the personal address and a private link.**
   The planned history rewrite changes commit author and committer emails
   only. Awake commits also put strings in file contents: the phase 1 plan
   (from `256e3c5`, "docs: Awake phase 1 implementation plan") held a `git -c
   user.email=<personal Gmail address>` command; the design spec (from
   `85f3501`, "docs: Awake design spec") and the plan held a private claude.ai
   mockup link; and `2ba6abc` wrote the home folder path, the personal address
   and the employer's name into the plan as search terms. The current tree is
   scrubbed, but every older commit still has them. *Proposal:* run the same
   rewrite with `git filter-repo --replace-text` for these strings. Only Awake
   commits contain them (checked with `git log --all -S`), so Insomnia's
   commits keep their hashes. *Otherwise:* accept that the address stays
   readable in old revisions of the plan.
2. **The commits already pushed keep the old address on GitHub.**
   `origin/main` (`256e3c5`) and `origin/phase-1` (`8c87e9a`) hold commits
   with the personal Gmail address as author and committer. A force-push
   leaves them unreachable, but GitHub can keep serving an unreachable commit
   by its hash, and it does not garbage-collect on request (only GitHub
   Support can purge). *Proposal:* the repository has no forks, stars, issues
   or releases (checked 2026-10-15), only the two Dependabot pull requests in
   point 3, so delete it and create it again under the same name, then push
   the rewritten `main` and `phase-1`. *Otherwise:* force-push and accept that
   someone who already knows an old hash could open it.
3. **Two open Dependabot pull requests are obsolete.** #1 (upload-artifact
   7.0.2) and #2 (download-artifact 8.0.2) bump actions that only Insomnia's
   release workflow used; that workflow was removed (`08e200c`). *Proposal:*
   close both and delete their `dependabot/…` branches (or let point 2's
   recreation drop them).
4. **GitHub Actions is disabled on the repository.** CI
   (`.github/workflows/ci.yml`) cannot run, but CONTRIBUTING.md says pull
   requests pass CI. *Proposal:* enable Actions when the repository goes
   public (Task 21). Hosted macOS runners are free on public repositories.
5. **Wiki and Projects are enabled.** Nothing uses them. *Proposal:* turn both
   off in Task 21, so issues stay the one place to report things.
6. **The app's copyright line was changed; confirm it.**
   `Resources/Info.plist` (`NSHumanReadableCopyright`, shown in Finder's Get
   Info) said "Copyright © 2026 Krish Garg. MIT License.", Insomnia's line. It
   now matches LICENSE: "Copyright © 2026 Liviu Lica. Portions copyright ©
   2026 Krish Garg. MIT License." Revert if you prefer the old line.
7. **Name.** README says "Awake" is a working title that may become Ember.
   Going public under `liviulica/awake` is fine either way: GitHub redirects a
   renamed repository. No action unless the name is settled first.

## 1. Secrets

- **History:** `gitleaks git --redact` (gitleaks 8.30.1) over every ref,
  including the `upstream` Insomnia branches: 561 commits scanned (the merge
  commits carry no diff of their own), no leaks found.
- **Working tree:** `gitleaks dir --redact` over the checkout, including the
  ignored `.build/` output (about 177 MB): no leaks found.
- **Binary assets:** `Resources/AppIcon-1024.png` and `Resources/AppIcon.icns`
  carry no author, path or user metadata (`strings`).
- Changed: nothing.

## 2. Personal data in commit metadata

- Seven author emails across all refs. Six belong to five Insomnia
  contributors (Krish Garg, with two addresses, Shikhar Shiromani, Batuhan
  Aydin, Danish Rafie, nsd97); their commits are never rewritten. GitHub's
  own `noreply@github.com` appears as committer of Insomnia's web merges.
- The maintainer's commits use a personal Gmail address as both author and
  committer: 55 commits on `phase-1` (this audit's included), 3 of them
  also on `main` and `origin/main`, 4 on `origin/phase-1`. The approved rewrite (to
  `826835+liviulica@users.noreply.github.com`) runs after this audit's
  commit, followed by setting this repository's `user.email` to that
  address. The repository has no local `user.email` today, and the global git
  identity is a different personal address, so a commit made without `-c`
  would leak that one.
- Trailers: `Co-Authored-By` lines name Claude and Codex models with their
  vendors' no-reply addresses; nothing personal.
- Nine Insomnia contributor commits carry `Claude-Session:
  https://claude.ai/code/session_…` links: five by Shikhar Shiromani (Insomnia
  PR #61, merged into `phase-1` by `8c87e9a`) and four by Batuhan Aydin
  (already on Insomnia's `main`). They are theirs, already public on
  Insomnia's repository, and stay as they are.
- Tags `v0.1.0` and `nightly-*` are Insomnia's. They exist only locally (none
  on `origin`); push branches by name, never with `--tags` or `--mirror`.
- Changed: nothing here (the rewrite is the controller's step).

## 3. Personal data in files

Searched every tracked file for the home folder path, the personal email
addresses, the maintainer's other handles, the employer's name, `claude.ai/`
links and `.superpowers`.

| Found | Where | Change |
|---|---|---|
| Personal Gmail address in a `git -c user.email=…` command | `docs/superpowers/plans/2026-10-14-awake-phase-1.md` | Now the no-reply address |
| Home folder path, personal address, employer name and the artifact link pattern as search terms in Task 20's text | same plan | Described in words |
| Private claude.ai mockup link (2 in the plan, 1 in the spec) | plan, `docs/superpowers/specs/2026-10-14-awake-design.md` | "(private mockup)" |
| `/Users/…` paths | Tests only, all made-up (`/Users/me`, `/Users/tester`, `/Users/x`, `/Users/u` in the plan) | None needed |
| `~/Coding/Awake`, `~/Coding/Insomnia` | plan | Already `~/…`; kept |
| `.superpowers/` (working notes of the build process) | Not tracked: ignored by its own `.gitignore` | Added `.superpowers/` to the root `.gitignore` too |

Values that are public on purpose and stay:

- **Bundle id `app.chargingpixels.awake`** (and the `.recovery` agent label,
  the `.keychain` queue label): `Resources/Info.plist`,
  `Sources/Insomnia/Store/Paths.swift`, `Sources/Insomnia/System/NetworkFailover.swift`,
  `scripts/install.sh`, `scripts/uninstall.sh`, `README.md`, the tests
  (`LaunchdBackstopTests`, `RecoveryScriptTests`, `StoreTests`,
  `PackagingTests`) and the design spec and plan.
- **Team id `4UA742BB8G`**: the design spec only (signing table and open
  question 5).
- **Name and handle:** "Liviu Lica" in LICENSE and Info.plist, `liviulica` in
  the clone URL and the plan.

`docs/superpowers/` (the design spec, the phase 1 plan and Insomnia's two
September design notes) stays public as design history.

## 4. Insomnia-only leftovers

| File | Found | Change |
|---|---|---|
| `.github/ISSUE_TEMPLATE/*` | Never existed in this repository | None |
| `.github/pull_request_template.md`, `docs/releasing.md`, `docs/release-validation.md`, `docs/install.md`, the release workflow | Already removed in `08e200c` | None |
| `SECURITY.md` | Contact said "if GitHub shows a Report a vulnerability action … otherwise open a public issue" | Contact is now GitHub private vulnerability reporting only (enabled in Task 21). The osascript SIGTERM window paragraph stays. |
| `CONTRIBUTING.md` | Already written for Awake | None |
| `docs/assets/session-flow.svg`, `docs/assets/lid-actions.svg`, `docs/assets/recovery-flow.svg` | Insomnia's README diagrams: eye icons, "Quit Insomnia", the Docker rule; referenced nowhere | Deleted |
| `docs/mockups/menubar-ux.html` | Insomnia's menu bar mockup ("Quit Insomnia", eye icon); referenced only by the deleted SVGs | Deleted |
| `docs/assets/eye-open.svg` | Still the app icon's source (PackagingTests, `scripts/generate-app-icon.sh`) | Kept |
| `docs/spec.md` | Insomnia's original spec, labelled as such, linked from the README | Kept |
| `.github/dependabot.yml` | Watches the CI workflow's pinned actions | Kept |

## 5. README for strangers

Checked against the list: what it is, screenshots, build from source, what the
installer changes, the one network request, uninstall, credits, license.

- Added a **Screenshots** section listing the planned images (the icon's three
  states, the menu without and with a lid session, the start prompt,
  Settings). None are taken yet.
- The clone line was a placeholder; it is now
  `git clone https://github.com/liviulica/awake.git` and `cd awake`.
- Added a **Credits** section (Insomnia and its contributors; Caffeine's
  authors).
- The License section links to [LICENSE](../LICENSE) again.
- Already present and unchanged: the build-from-source install (no signed
  release), the three-line sudoers rule and the recovery LaunchAgent, the
  single `captive.apple.com` request, uninstall.

LICENSE: the Caffeine section's intro now reads "Awake's one-click mode
follows the idea of Caffeine:". The Caffeine copyright lines and text are
unchanged.

## 6. Repository metadata (applied in Task 21)

Current: private, not a GitHub fork, description "Keep your Mac awake, even
with the lid closed. Working title; fork of krishhgg/Insomnia.", no topics,
no homepage.

Proposed for Task 21:

- **Description:** "Keep your Mac awake, even with the lid closed. A menu bar
  app for long jobs and coding agents. Fork of krishhgg/Insomnia."
- **Topics:** `macos`, `menu-bar`, `caffeinate`, `sleep`, `ai-agents`.
- **Homepage:** none.
- **Security:** enable private vulnerability reporting (SECURITY.md now
  depends on it).
- Plus the settings in open decisions 2 to 5.

## Verification

- `swift build -c release -Xswiftc -warnings-as-errors`: build complete.
- `scripts/test-fast.sh`: 970 tests, 0 failures.
- `swift test --filter PackagingTests` (Info.plist changed): 20 tests, 0
  failures.
- `plutil -lint Resources/Info.plist`: OK.
- `shellcheck --shell=bash scripts/*.sh` (no script changed): clean.
- Re-ran the personal-data search on the tree after the changes: no matches
  outside the intended values above and this file's own description of the
  search.
