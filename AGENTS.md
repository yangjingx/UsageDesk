# UsageDesk project workflow

- Before adding a feature or fixing an interaction, review the relevant official framework APIs and existing solutions or similar issues on GitHub; use that research to choose the implementation before editing code.
- This repository's `main` branch is the public GitHub source of truth for UsageDesk.
- Track `README.md`, all root Swift source files, `assets/` including the provider marks, `UsageDesk-icon.png`, and the approved release package `UsageDesk.zip` in the repository. `outputs/` contains local deliverables and `work/` contains temporary build files; both are ignored by Git.
- When preparing an approved release, keep the root source and package in sync with the corresponding files under `outputs/`. Keep unapproved preview packages separate from the released root package.
- Keep new versions local until the user has tested them, says they meet the release standard, and explicitly authorizes publishing. Only then commit and push `main` and publish the GitHub Release. Do not publish previews or unapproved builds.
- Never commit local usage snapshots, authentication files, tokens, or private user data.
- After the user authorizes a version's publication, create or update a GitHub Release tagged with that version and attach `UsageDesk.zip`; verify the asset is visible before reporting completion.
- Write every GitHub Release changelog in both Chinese and English.
