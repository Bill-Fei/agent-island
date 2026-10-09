# Top Island Activity Count - 2026-10-09

## Cause and Scope

The compact number was derived from `ongoingTasks.count`. The persisted
membership tracks unresolved turns, including stale permission checks and
unknown source states; it does not prove that every retained turn is active now.

This revision adds cached `currentActivityTasks` (ongoing membership intersected
with the existing provider freshness rule). Compact numbers, secondary agent
icons, and medium multi-task text use that collection. Fresh tasks take priority
over a historical selection. An unresolved long task can retain a quiet compact
presence when activity is unknown, without a number or a historical icon stack.

No raw task is completed, deleted, or cancelled by the counting change. No
approval protocol, source identity, or freshness threshold is changed. The count
represents observed task activity, not the number of application processes.

## Verification

- Production Swift sources compiled with the project's contained compiler path.
- `bash script/check_sandbox.sh`: PASS, including shared checks, alpha setup,
  236 production TaskStore checks, 3 background-store checks, 514 bridge checks,
  and 61 isolated Claude approval checks. These fixtures do not certify provider
  end-to-end approval or continuous hover frame rate.
- Added 11 targeted checks: five previously observed starts; four become stale
  or explicitly unknown; one remains current; number and icons are one; history
  and raw states survive; restart and freshness boundaries are correct; two
  fresh tasks from the same provider remain separate.
- Independent read-only source review: PASS, no blocking findings.
- Final real-data probe used copies of `state.json`, `events.jsonl`, and
  `hook-turns.json` in `/private/tmp/island-real-count-snapshot.HI4FRt`. It reported
  `ongoing=7`, `currentActivity=1`, `compactCount=1`, one Codex icon, and the
  current tool-execution label. The probe did not write to the personal source.
- Packaged via `bash script/build_and_run.sh --package-validated`; normal-mode
  process verified at PID 1941; build ID `20261009174803`.
- Actual app accessibility readout and screenshot show one Codex icon and tool
  execution activity, without the former `5`. This is a static visual check;
  continuous hover motion and every provider's live status are NOT VERIFIED by
  this revision.

## Shared Working Tree

TaskStore and its acceptance file already contained uncommitted lifecycle
changes before this revision. Those changes are preserved. The source edits
are not committed as whole files here, because doing so would also commit
another session's work. This record is committed separately; the source patch
is present in the verified and launched normal-mode build.
