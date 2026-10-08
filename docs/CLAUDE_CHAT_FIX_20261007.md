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

## Permission Refresh Result — 2026-10-08

- With user approval and user-completed system authentication, the island's Accessibility switch was changed from on to off, then back to on. Claude's own switch was not changed.
- Restarted the existing development bundle without rebuilding. A new process runs from `dist/Agent 灵动岛.app` without QA arguments. The bundle passes `codesign --verify --deep --strict`.
- Selected that exact development bundle in the Accessibility Add dialog. The list continues to show the island enabled, but the island's own diagnostic still reports no Accessibility trust.
- The development and Release bundles have different ad-hoc designated code-hash requirements. This supports the stale-identity hypothesis but does not prove the TCC denial cause.
- No permission database was edited or bypassed, and no Chat message was sent. Removing the existing stale permission entry and adding the current bundle is a separate proposed recovery step requiring explicit confirmation; it would not delete the application or task data.
- Stop repeating toggles or builds while trust remains false. End-to-end Chat acceptance remains **NOT VERIFIED**.

## Build Identity Follow-up — 2026-10-08

- With explicit user approval, `tccutil reset Accessibility com.billfei.linglongtai.hud` removed only this application's old grant. The current development bundle was selected again. The island briefly reported `Claude Chat：未读到窗口`, which means the trust gate passed at that observation; it is not Chat lifecycle evidence.
- The bundle later inspected had revision `fe843d9-dirty`, build `20261008151222` and ad-hoc CDHash `2bf332fe95386bbdd86a9a7a1402329c586d9485`, different from the earlier `251144e-dirty` build. Its binary modification time was 15:12:30. The island subsequently reported permission required again. These observations strongly support a rebuild/identity collision, but no TCC decision log was obtained to prove causality.
- Read-only `security find-identity -p codesigning -v` reports **0 valid identities**. No certificate was created/imported, no trust setting changed, and no designated requirement was weakened.
- L2 build workflow repair: validate modes and any explicitly configured certificate fingerprint before building; serialize concurrent script runs; verify source/resource fingerprints after compilation; retain an unchanged signed bundle after verifying its seal and build fingerprints. Changed builds still require packaging, so ad-hoc permissions may still require refreshing. The script prints that limitation instead of implying it fixes authorization automatically.
- `ISLAND_SIGNING_IDENTITY` optionally pins an existing valid certificate by its 40-character SHA-1 fingerprint. A certificate-based build and permission persistence across an actual update remain **NOT VERIFIED**; no valid identity is available locally.
- Bash syntax and packaging fixture checks are separate from compiling/running the Swift app. Normal SwiftPM compilation failed with `sandbox_apply: Operation not permitted`; both authorized retry attempts expired in the automatic permission reviewer. They did not package or relaunch the app. UI inspection reported the Mac locked.
- `bash -n script/build_and_run.sh`: PASS. `python3 script/check_build_workflow.py`: 8 isolated fixtures PASS (unchanged signed bundle reuse, changed resources, changed binaries/helpers, restart dispatch, failed build preservation, concurrent lock, signer change, invalid signer/mode). All compiler/signing/launch actions are fixture stubs; no real app or keychain is touched by those tests.

Real user-initiated Chat generation → island running state → real completion remains **NOT VERIFIED**. Do not ask the user to repeatedly toggle permission while other workflows replace the executable. Resume by keeping one current bundle stable, checking its own trust diagnostic, then observing a user-initiated Chat turn.
