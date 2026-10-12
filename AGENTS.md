# MonPlayer ClearKey Lab working rules

- Before implementing every new user request, append its requirements,
  acceptance checks and current status to the private journal:
  `D:/Code_app/MonPlayer-ClearKey-private/NHAT_KY_DE_BAI.md`.
- Follow the journal's approved stages sequentially. Do not omit unfinished
  items or mark an item complete based on build success alone.
- Preserve working CK2 and original MonPlayer artifacts. Keep provider/QR,
  Dell services, Nam Solar and signing identities outside a focused change.
- This public repository and CI may contain only integration source,
  dependency references and owned synthetic fixtures. Never add real user
  playlists, credentials, content keys, third-party IPA/source or private logs.
- Work only with legitimately supplied keys and provider-authorized license
  flows. Never guess missing keys, extract CDM secrets or disable TLS checks.
- Distinguish local/static, simulator and physical-device/user-reported tests.
  Release records must include version/build, SHA256, actual verification
  evidence, known limits and rollback instructions.
- Manual edits use apply_patch; retain unrelated existing changes.
