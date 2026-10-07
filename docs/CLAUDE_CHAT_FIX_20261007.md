# Claude Chat Observation Repair

## Scope

User enabled Accessibility and sent a Claude message, but reported no island response.
The previous delivery confirmed compilation, not the real Chat-to-island lifecycle.

## Confirmed Evidence

- Claude Desktop's current AX tree exposes `Stop`, `Currently streaming message`, and a responding status. The inspected window was the Code (`epitaxy`) page, not ordinary Chat.
- No `ClaudeChat*` task was present in the personal task snapshot during inspection. Only filtered status metadata is needed for diagnosis.
- Two bundles share the same application ID: `dist/Agent 灵动岛.app` and `dist/Release/Agent 灵动岛.app`. The older Release executable lacks the Chat observer. Which executable handled the user's test remains unverified.

## Changes (L3)

- Show permission, missing-window, unsupported-page, Code-mode, and Chat-generation diagnostics in Settings instead of failing silently.
- Match current Stop/Send controls; skip static text, inputs, headings, links, and known message/sidebar subtrees. No message/input values are read. Read only allowlisted document-route metadata to derive a hashed conversation ID; never persist or emit the URL, page title, or raw conversation ID.
- Distinguish Code from Chat/Cowork. Unknown routes fail closed; Code continues to use its Hook integration.
- Use a serial-in-flight utility task for bounded AX scans, not the main animation thread. Unchanged observations are deduplicated; a confirmed running observation refreshes task activity every 30 seconds.
- On window/page/permission loss or incomplete AX reads, retain unknown status. Communication failures cannot supply completion evidence.
- Conversation navigation cannot complete a different conversation. After restart, old active rows remain unknown; new observed generations do not reuse their turn IDs.

## Verification

- `bash script/check_sandbox.sh`: PASS. Full source compile; 507 shared checks, 197 TaskStore checks, 3 background-store checks, 514 Hook bridge checks, 20 permission-observer checks, and native setup fixtures. Temporary test data only; these are not provider end-to-end evidence.
- `./script/build_and_run.sh --package-validated`: PASS. Packaged the checked executable into `dist/Agent 灵动岛.app`; did not launch it or replace the running process.
- Independent source review: PASS with no blocking findings after conversation identity, text privacy, AX transport-error, and restart turn-identity issues were addressed. This is source review, not real Chat end-to-end acceptance.
- Launch approval review timed out twice. Desktop inspection then reported a locked Mac. No security settings, credentials, Hook configurations, or Claude messages were changed.

## Acceptance Boundary

Real Chat generation to visible island task and real end-state: **NOT VERIFIED**.
Root cause of the user's individual failed run is not yet proven. Missing Stop compatibility, a silent permission/window failure, or an old Release process are separate hypotheses; do not describe any one as confirmed without the running app's diagnostics.

After unlocking, verify the actual app path and Settings diagnosis, then observe a user-initiated Chat generation and ending. Accessibility permission is app-specific; a granted permission in the desktop automation tool is not evidence that the island process is trusted. Short responses between polls and hidden/unrendered conversations remain outside this experimental observer's guarantee.
