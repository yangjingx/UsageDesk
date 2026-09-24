# UsageDesk project workflow

- Before adding a feature or fixing an interaction, review the relevant official framework APIs and existing solutions or similar issues on GitHub; use that research to choose the implementation before editing code.
- This repository's `main` branch is the public GitHub source of truth for UsageDesk.
- Track `README.md`, `UsageDesk.swift`, `UsageDesk-icon.png`, and `UsageDesk.zip` in the repository. `outputs/` contains local deliverables and `work/` contains temporary build files; both are ignored by Git.
- When updating the app, keep the root source and package in sync with the corresponding files under `outputs/`.
- After each completed and verified update, commit the changed project files and push `main` to `origin` during the same task. Confirm the push succeeded before reporting that GitHub is updated. If authentication or network access prevents pushing, report that clearly.
- Never commit local usage snapshots, authentication files, tokens, or private user data.
- For each app version, create or update a GitHub Release tagged with that version and attach `UsageDesk.zip`; verify the asset is visible before reporting completion.
- Write every GitHub Release changelog in both Chinese and English.
