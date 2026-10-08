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

## Runtime Follow-up — 2026-10-08

- The inspected island process was launched with `--qa-demo`. This in-memory acceptance mode returns before real event polling and Chat observer startup. It explains why that inspected process cannot react to Chat; it does not prove which mode was used for the user's earlier test.
- The normal build/run workflow subsequently launched the development bundle without QA arguments. Its Settings reports version `0.3.1`, revision `251144e-dirty`, and `Claude Chat：灵动岛尚未获得辅助功能授权`.
- System Settings shows the existing `Agent 灵动岛` Accessibility switch **on**, while the currently running island continues to report no trust. The development bundle's designated requirement is its ad-hoc code hash. A stale grant after rebuilding or a grant for the other same-ID bundle is plausible, not yet proven.
- The Accessibility page has been opened, but no permission switches, system settings, or Claude messages were changed. Refreshing the grant requires explicit user confirmation. Do not enable Claude's own Accessibility switch; the observing island is the process that needs permission.
- Real Chat generation and completion remain **NOT VERIFIED**, blocked on authorization of the current island executable and a user-initiated Chat turn.
