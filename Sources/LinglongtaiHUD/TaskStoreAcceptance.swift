import Foundation
import LinglongtaiShared

/// Runs the production TaskStore against an explicitly selected temp directory.
/// Test events never go to the user's application-support directory.
@MainActor
enum TaskStoreAcceptance {
    static func run() {
        let root = LinglongtaiPaths.applicationSupport
        guard ProcessInfo.processInfo.arguments.contains("--data-dir"),
              root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix("/tmp/") else {
            fputs("self-test requires --data-dir in /tmp\n", stderr)
            return
        }
        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append((condition ? "PASS: " : "FAIL: ") + name)
        }
        func emit(_ event: AgentEvent) throws {
            let data = try JSONEncoder().encode(event)
            let handle = try FileHandle(forWritingTo: LinglongtaiPaths.events)
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
            try handle.close()
        }
        do {
            let store = TaskStore()
            check("empty startup has no fabricated tasks", store.sortedTasks.isEmpty && store.presentation == .collapsed)
            check("context menu cannot open from collapsed island", !store.beginContextMenu())
            store.showTaskDetails()
            check("context menu opens only from expanded details", store.beginContextMenu() && store.contextMenuIsOpen)
            check("nested context menu is rejected", !store.beginContextMenu())
            store.samplePointer(inside: false, at: 1)
            store.samplePointer(inside: false, at: 10)
            store.refreshPresentation()
            check("moving into menu outside island retains its anchor", store.presentation == .heavy)
            store.endContextMenu()
            check("closing menu releases anchor instead of sticking open", !store.contextMenuIsOpen && store.presentation == .collapsed)
            store.samplePointer(inside: true, at: 20)
            store.samplePointer(inside: true, at: 20.21)
            check("hover works again after menu dismiss", store.presentation == .heavy)
            _ = store.beginContextMenu()
            store.endContextMenu(pointerInside: true)
            check("cancelling menu while still inside retains details without flashing", store.presentation == .heavy && !store.contextMenuIsOpen)
            store.samplePointer(inside: true, at: 21)
            store.samplePointer(inside: true, at: 21.21)
            store.samplePointer(inside: false, at: 22)
            store.samplePointer(inside: false, at: 22.16)
            check("leaving after inside cancel still collapses normally", store.presentation == .collapsed)
            store.showTaskDetails()
            _ = store.beginContextMenu()
            store.resetInteraction()
            check("hiding resets context menu tracking", !store.contextMenuIsOpen && store.presentation == .collapsed)
            let first = UUID(), second = UUID()
            try emit(AgentEvent(type: "upsert", id: first, agent: "Claude", title: "test old waiting", status: .waiting,
                                createdAt: Date().addingTimeInterval(-240)))
            try emit(AgentEvent(type: "upsert", id: second, agent: "Claude", title: "test recent completion", status: .completed))
            store.consumeEvents()
            check("latest provider status uses timestamp not status rank", store.latestKnownLiveTask(for: .claude)?.id == second)
            check("stale waiting retains history without a current user-action counter", store.waitingCount == 0 &&
                  store.liveTasks.contains { $0.id == first && $0.status == .waiting })
            if let staleWaiting = store.tasks.first(where: { $0.id == first }) {
                check("unadopted stale waiting shows an unknown result, never a third state", store.displayedStatus(for: staleWaiting) == "结果未知")
            }
            let beforePreview = store.tasks
            store.loadDemoTasks()
            check("preview is separated and includes recent finished history", store.tasks == beforePreview && store.sortedTasks.count == 4)
            store.clearFinished()
            store.endDemoPreview()
            check("preview cleanup cannot change real tasks", store.tasks == beforePreview)
            store.loadDemoTasks()
            let third = UUID()
            try emit(AgentEvent(type: "upsert", id: third, agent: "Codex", title: "test live update", status: .running, progress: 0.4))
            store.consumeEvents()
            check("live event exits preview without losing tasks", !store.demoPreviewActive && store.tasks.count == 3)
            check("persisted data never contains demo", store.tasks.allSatisfy { $0.source == .liveEvent })
            let beforeCommand = store.tasks
            if let task = store.tasks.first(where: { $0.id == third }) { store.perform(.stop, for: task) }
            check("command does not fabricate provider state", store.tasks == beforeCommand)
            let commands = try String(contentsOf: LinglongtaiPaths.commands, encoding: .utf8)
            check("command request actually written", commands.contains("stop"))
            try emit(AgentEvent(type: "upsert", id: third, status: .completed, progress: 1))
            store.consumeEvents()
            try emit(AgentEvent(type: "upsert", id: third, status: .running, createdAt: Date().addingTimeInterval(-300)))
            store.consumeEvents()
            check("older event cannot roll completed state backward", store.tasks.first { $0.id == third }?.status == .completed)
            let reloaded = TaskStore()
            check("restart restores atomic snapshot and cursor", reloaded.tasks == store.tasks)
            reloaded.clearAllTasks()
            let emptyReload = TaskStore()
            check("clear is not undone by old event replay", emptyReload.tasks.isEmpty)
            let chatStore = TaskStore()
            let observer = ClaudeChatObserver()
            let routeA = ClaudeChatObserver.documentIdentity(url: URL(string: "app://localhost/cowork/conversation-A")!, pid: 42, launch: 1)
            let routeB = ClaudeChatObserver.documentIdentity(url: URL(string: "app://localhost/cowork/conversation-B")!, pid: 42, launch: 1)
            check("Claude Chat same-window conversations have separate hashed identities", routeA.sessionID != nil &&
                  routeA.sessionID != routeB.sessionID && !routeA.sessionID!.contains("conversation-A"))
            check("Claude Chat Code route never creates a chat identity",
                  ClaudeChatObserver.documentIdentity(url: URL(string: "app://localhost/epitaxy/local-A")!, pid: 42, launch: 1).codeMode)
            check("Claude Chat unknown document routes fail closed",
                  ClaudeChatObserver.documentIdentity(url: URL(string: "file:///Applications/Claude.app/index.html")!, pid: 42, launch: 1).sessionID == nil)
            check("Claude Chat AX communication failures invalidate completion evidence",
                  ClaudeChatObserver.isBlocking(.cannotComplete) && ClaudeChatObserver.isBlocking(.invalidUIElement) &&
                  ClaudeChatObserver.isBlocking(.apiDisabled) && ClaudeChatObserver.isBlocking(.failure))
            check("Claude Chat absent optional AX attributes are not transport failures",
                  !ClaudeChatObserver.isBlocking(.success) && !ClaudeChatObserver.isBlocking(.attributeUnsupported) &&
                  !ClaudeChatObserver.isBlocking(.noValue))
            var observed: [ClaudeChatObserver.Snapshot] = []
            var diagnostics: [ClaudeChatObserver.Diagnostic] = []
            observer.onSnapshot = { snapshot in
                observed.append(snapshot)
                chatStore.applyClaudeChatSnapshot(snapshot)
            }
            observer.onDiagnostic = { diagnostics.append($0) }
            let observedAt = Date()
            observer.receive(.init(diagnostic: .permissionRequired), at: observedAt)
            check("Claude Chat missing permission exposes diagnostics without inventing a task",
                  diagnostics == [.permissionRequired] && observed.isEmpty && chatStore.tasks.isEmpty)
            observer.receive(.init(diagnostic: .codeMode), at: observedAt)
            check("Claude Code mode does not duplicate its hook task", observed.isEmpty && chatStore.tasks.isEmpty)
            observer.receive(.init(diagnostic: .running, sessionID: "chat-A", running: true), at: observedAt)
            let firstChatID = chatStore.tasks.first?.id
            check("Claude Chat real running signal creates one event-backed turn",
                  chatStore.tasks.count == 1 && chatStore.tasks.first?.status == .running &&
                  chatStore.tasks.first?.progressKnown == false && chatStore.tasks.first?.requiresApproval == false)
            let countBeforeHeartbeat = observed.count
            observer.receive(.init(diagnostic: .running, sessionID: "chat-A", running: true), at: observedAt.addingTimeInterval(1))
            check("Claude Chat identical polls do not invalidate the view tree", observed.count == countBeforeHeartbeat)
            observer.receive(.init(diagnostic: .running, sessionID: "chat-A", running: true), at: observedAt.addingTimeInterval(31))
            check("Claude Chat long-task heartbeat retains a single turn", observed.count == countBeforeHeartbeat + 1 && chatStore.tasks.count == 1)
            observer.receive(.init(diagnostic: .unreadable, sessionID: "chat-A", idle: true, scanComplete: false))
            check("Claude Chat partial tree cannot fabricate completion", observed.last?.phase == .unknown &&
                  chatStore.tasks.first?.status == .running && chatStore.tasks.first.map { chatStore.displayedStatus(for: $0) } == "结果未知")
            observer.receive(.init(diagnostic: .idle, sessionID: "chat-B", idle: true))
            check("Claude Chat another window cannot complete the running window", observed.last?.phase == .unknown)
            observer.receive(.init(diagnostic: .running, sessionID: "chat-B", running: true))
            check("Claude Chat switching running windows keeps separate tasks", chatStore.tasks.count == 2 &&
                  chatStore.tasks.first(where: { $0.id == firstChatID })?.sourceEvent == "ClaudeChatUnknown")
            observer.receive(.init(diagnostic: .idle, sessionID: "chat-B", idle: true))
            check("Claude Chat return of send control ends only the observed turn",
                  chatStore.tasks.first(where: { $0.sessionID == "chat-B" })?.status == .completed &&
                  chatStore.tasks.first(where: { $0.sessionID == "chat-A" })?.status == .running)
            observer.receive(.init(diagnostic: .running, sessionID: "chat-B", running: true))
            check("Claude Chat next generation creates a new turn", chatStore.tasks.filter { $0.sessionID == "chat-B" }.count == 2)
            chatStore.clearAllTasks()
            store.setNotchOffset(-8)
            store.setNotchWidthAdjustment(24)
            check("both calibration setters accept adjustments", store.notchOffset == -8 && store.notchWidthAdjustment == 24)
            store.setNotchOffset(0)
            store.setNotchWidthAdjustment(0)

            // Exercise the production mapper -> JSONL -> store -> snapshot path.
            // The earlier clear checkpoint makes this an isolated second phase.
            let hookStore = TaskStore()
            let providers: [AgentKind] = [.codex, .claude, .workBuddy]
            let session = "acceptance-shared-session"
            let privateMarker = "HOOK_INTEGRATION_PRIVACY_SENTINEL"
            let privateFields: [String: Any] = [
                "prompt": privateMarker, "user_prompt": privateMarker,
                "body": privateMarker, "message": privateMarker,
                "last_assistant_message": privateMarker,
                "tool_name": privateMarker, "tool_input": ["command": privateMarker],
                "tool_output": privateMarker, "tool_response": ["content": privateMarker],
                "cwd": "/private/" + privateMarker,
                "transcript_path": "/private/" + privateMarker,
                "environment": ["TOKEN": privateMarker], "progress": 0.87
            ]
            var hookTime = Date().addingTimeInterval(-60)
            @discardableResult
            func emitHook(_ provider: AgentKind, _ name: String, sessionID: String? = nil,
                          extra: [String: Any] = [:]) throws -> AgentEvent? {
                var input: [String: Any] = ["hook_event_name": name, "session_id": sessionID ?? session]
                input.merge(extra) { _, replacement in replacement }
                let payload = try JSONSerialization.data(withJSONObject: input)
                hookTime.addTimeInterval(1)
                guard let event = HookEventMapper.map(provider: provider, payload: payload, now: hookTime) else {
                    return nil
                }
                try emit(event)
                return event
            }

            for provider in providers { try emitHook(provider, "SessionStart", extra: privateFields) }
            hookStore.consumeEvents()
            check("SessionStart connects three providers without inventing tasks",
                  hookStore.tasks.isEmpty && hookStore.presentation == .collapsed &&
                  providers.allSatisfy { hookStore.connections[$0.rawValue] != nil })
            check("connected providers still report waiting for their first task",
                  providers.allSatisfy { hookStore.statusSummary(for: $0) == "已收到连接 · 等待任务" })

            for provider in providers { try emitHook(provider, "UserPromptSubmit", extra: privateFields) }
            hookStore.consumeEvents()
            check("same session ID across three providers creates three independent tasks",
                  hookStore.tasks.count == 3 && Set(hookStore.tasks.map(\.id)).count == 3 &&
                  providers.allSatisfy { provider in
                      hookStore.tasks.filter { $0.profile.kind == provider }.count == 1 &&
                      hookStore.latestKnownLiveTask(for: provider)?.status == .running
                  })
            check("hook tasks and visible summaries never invent percentages",
                  hookStore.tasks.allSatisfy { !$0.progressKnown && $0.source == .liveEvent } &&
                  providers.allSatisfy { !hookStore.statusSummary(for: $0).contains("%") })

            for provider in providers {
                guard let initial = hookStore.latestKnownLiveTask(for: provider) else {
                    check("\(provider.rawValue) lifecycle fixture exists", false)
                    continue
                }
                let unaffected = hookStore.tasks.filter { $0.id != initial.id }
                try emitHook(provider, "PermissionRequest", extra: privateFields)
                hookStore.consumeEvents()
                let waiting = hookStore.latestKnownLiveTask(for: provider)
                check("\(provider.rawValue) permission callback waits for user confirmation",
                      waiting?.id == initial.id && waiting?.status == .waiting && waiting?.requiresApproval == true)

                for name in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
                    try emitHook(provider, name, extra: privateFields)
                    hookStore.consumeEvents()
                    let running = hookStore.latestKnownLiveTask(for: provider)
                    check("\(provider.rawValue) \(name) resumes running without fabricated progress",
                          running?.id == initial.id && running?.status == .running &&
                          running?.requiresApproval == false && running?.progressKnown == false &&
                          running?.sourceEvent == name)
                }

                try emitHook(provider, "Stop", extra: privateFields)
                hookStore.consumeEvents()
                let completed = hookStore.latestKnownLiveTask(for: provider)
                check("\(provider.rawValue) Stop completes only the current round",
                      completed?.status == .completed && completed?.statusLabel == "本轮已结束")
                try emitHook(provider, "SessionEnd", extra: privateFields)
                hookStore.consumeEvents()
                check("\(provider.rawValue) SessionEnd preserves a completed round",
                      hookStore.latestKnownLiveTask(for: provider) == completed)

                try emitHook(provider, "UserPromptSubmit", extra: privateFields)
                hookStore.consumeEvents()
                let resumed = hookStore.latestKnownLiveTask(for: provider)
                check("\(provider.rawValue) another round reuses the same session and returns to running",
                      resumed?.id == initial.id && resumed?.status == .running &&
                      resumed?.sourceEvent == "UserPromptSubmit" &&
                      hookStore.tasks.filter { $0.id == initial.id }.count == 1)

                try emitHook(provider, "StopFailure", extra: privateFields)
                hookStore.consumeEvents()
                let failed = hookStore.latestKnownLiveTask(for: provider)
                check("\(provider.rawValue) StopFailure records failure without progress",
                      failed?.status == .failed && failed?.progressKnown == false && failed?.requiresApproval == false)
                try emitHook(provider, "SessionEnd", extra: privateFields)
                hookStore.consumeEvents()
                check("\(provider.rawValue) SessionEnd preserves an already failed round",
                      hookStore.latestKnownLiveTask(for: provider) == failed)

                try emitHook(provider, "UserPromptSubmit", extra: privateFields)
                try emitHook(provider, "SessionEnd", extra: privateFields)
                hookStore.consumeEvents()
                let ended = hookStore.latestKnownLiveTask(for: provider)
                check("\(provider.rawValue) SessionEnd closes an active round",
                      ended?.status == .cancelled && ended?.statusLabel == "会话已关闭" &&
                      ended?.requiresApproval == false)
                check("\(provider.rawValue) lifecycle never changes either other provider",
                      hookStore.tasks.filter { $0.id != initial.id } == unaffected)
            }

            let beforeIgnored = hookStore.tasks
            var allIgnored = true
            for provider in providers {
                let unknown = try emitHook(provider, "FutureUnknownEvent")
                let subagent = try emitHook(provider, "Stop", extra: ["agent_id": "nested-agent"])
                let irrelevant = try emitHook(provider, "Notification", extra: ["notification_type": "idle_prompt"])
                allIgnored = allIgnored && unknown == nil && subagent == nil && irrelevant == nil
                try emitHook(provider, "SessionEnd", sessionID: "never-started-session")
            }
            hookStore.consumeEvents()
            check("unknown, subagent, unrelated notifications and orphan session ends cannot create or change tasks",
                  allIgnored && hookStore.tasks == beforeIgnored)
            let eventLog = try String(contentsOf: LinglongtaiPaths.events, encoding: .utf8)
            let snapshot = try String(contentsOf: LinglongtaiPaths.state, encoding: .utf8)
            let exportedTasks = try String(contentsOf: LinglongtaiPaths.tasks, encoding: .utf8)
            check("metadata-only hooks never persist prompt, tool data, body, paths or raw session IDs",
                  [eventLog, snapshot, exportedTasks].allSatisfy {
                      !$0.contains(privateMarker) && !$0.contains(session)
                  })
            let hookReload = TaskStore()
            check("restart preserves hook states and connection metadata without replay",
                  hookReload.tasks == hookStore.tasks && hookReload.connections == hookStore.connections)
            // Doubao state now arrives through its local trajectory, but this
            // harness is isolated from the personal directory, so none can
            // appear here. This proves nothing is invented without a source;
            // live derivation is covered by DoubaoRevisionChecks instead.
            check("Doubao invents no task status without a trajectory present",
                  hookReload.statusSummary(for: .doubao) == "等待首次任务回调" &&
                  hookReload.latestKnownLiveTask(for: .doubao) == nil)
            hookReload.clearAllTasks()
            try runPresentationRevisionChecks(check: check, emit: emit)
            try runTrackedHookRevisionChecks(check: check, emit: emit)
            try runButlerStoreChecks(check: check, emit: emit)
            try runReleaseStoreChecks(check: check, emit: emit)
            try runClaudeApprovalStoreChecks(check: check, emit: emit)
            try runSizingRefreshChecks(check: check, emit: emit)
            try runAmbientEvidenceChecks(check: check, emit: emit)
            try runCurrentActivityCountChecks(check: check, emit: emit)
        } catch {
            results.append("FAIL: test harness error: \(error)")
        }
        let report = results.joined(separator: "\n") + "\n"
        try? report.write(to: root.appendingPathComponent("acceptance.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    private static func runAmbientEvidenceChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
        var date = Date()
        let store = TaskStore(now: { date })
        store.clearAllTasks()
        store.setAutoPopOnEvent(true)
        store.setHeavyOnHover(true)
        let oldCodexA = UUID(), oldCodexB = UUID(), silentDoubaoA = UUID(), silentDoubaoB = UUID()
        for (id, agent, event, age) in [
            (oldCodexA, "Codex", "PostToolUse", 14 * 3_600.0),
            (oldCodexB, "Codex", "PostToolUse", 15 * 3_600.0),
            (silentDoubaoA, "豆包", "DoubaoSilent", 4 * 3_600.0),
            (silentDoubaoB, "豆包", "DoubaoSilent", 5 * 3_600.0)
        ] {
            try emit(AgentEvent(type: "upsert", id: id, agent: agent, status: .running,
                                createdAt: date.addingTimeInterval(-age), sourceEvent: event))
        }
        store.consumeEvents()
        let unresolved = store.tasks
        check("ambient evidence: screenshot's four unresolved rows stay in 24h history", store.liveTasks.count == 4 && store.sortedTasks.count == 4)
        check("ambient evidence: four stale rows cannot keep island open", store.presentation == .collapsed && !store.hasLiveEvent)
        check("ambient evidence: stale rows create no count, icons or execution motion", store.compactCountText.isEmpty &&
              store.islandIconTasks.isEmpty && store.activeTask == nil && !store.activeTaskIsExecuting)
        let reload = TaskStore(now: { date })
        check("ambient evidence: restart cannot resurrect stale ambient activity", reload.tasks == unresolved &&
              reload.presentation == .collapsed && reload.compactCountText.isEmpty)
        store.selectedTaskID = oldCodexA
        store.samplePointer(inside: true, at: 20)
        store.samplePointer(inside: true, at: 20.21)
        check("ambient evidence: stale history remains reachable by hover", store.presentation == .heavy && store.selectedTask?.id == oldCodexA)
        store.samplePointer(inside: false, at: 21)
        store.samplePointer(inside: false, at: 21.16)
        check("ambient evidence: leaving stale history returns to hardware notch", store.presentation == .collapsed && store.tasks == unresolved)

        let active = UUID()
        try emit(AgentEvent(type: "upsert", id: active, agent: "WorkBuddy", status: .running,
                            createdAt: date, sourceEvent: "UserPromptSubmit"))
        store.consumeEvents()
        check("ambient evidence: new real task appears without inflating count from history", store.presentation == .medium &&
              store.compactCountText == "1" && store.islandIconTasks.map(\.id) == [active] && store.activeTask?.id == active)
        date.addTimeInterval(10)
        store.refreshPresentation()
        check("ambient evidence: stale selection cannot displace fresh compact task", store.presentation == .compact &&
              store.selectedTask?.id == oldCodexA && store.activeTask?.id == active && store.activeTaskIsExecuting)
        for _ in 0..<6 {
            date.addTimeInterval(90)
            try emit(AgentEvent(type: "upsert", id: active, agent: "WorkBuddy", status: .running,
                                createdAt: date, sourceEvent: "PostToolUse"))
            store.consumeEvents()
        }
        check("ambient evidence: a long task with actual updates stays compact", store.presentation == .compact &&
              store.activeTask?.id == active && store.activeTaskIsExecuting && store.compactCountText == "1")
        let beforeExpiry = store.tasks
        date.addTimeInterval(120)
        store.refreshPresentation()
        check("ambient evidence: exact freshness boundary remains active", store.presentation == .compact && store.compactCountText == "1")
        date.addTimeInterval(0.01)
        store.refreshPresentation()
        check("ambient evidence: a quiet stretch keeps counting the started task", store.presentation == .compact &&
              store.hasLiveEvent && store.activeTask?.id == active && store.islandIconTasks.count == 1 && store.compactCountText == "1" && store.activeTaskIsExecuting &&
              store.tasks == beforeExpiry && store.tasks.first(where: { $0.id == active })?.status == .running)

        for (provider, name, status) in [("豆包", "DoubaoSilent", AgentTaskStatus.running),
                                          ("豆包", "DoubaoAbandoned", .cancelled),
                                          ("Claude", "ClaudeChatUnknown", .running),
                                          ("Codex", "AmbiguousTurn", .running)] {
            let id = UUID()
            try emit(AgentEvent(type: "upsert", id: id, agent: provider, status: status,
                                createdAt: date, sourceEvent: name))
            store.consumeEvents()
            check("ambient evidence: fresh-timestamp \(name) is not counted as running", store.presentation == .compact &&
                  store.compactCountText == "1" && store.ongoingTasks.map(\.id) == [active] && store.currentActivityTasks.map(\.id) == [active])
        }
        try emit(AgentEvent(type: "upsert", id: active, agent: "WorkBuddy", status: .running,
                            createdAt: date, sourceEvent: "PreToolUse"))
        store.consumeEvents()
        check("ambient evidence: resumed actual tool restores only the real task", store.presentation == .compact &&
              store.compactCountText == "1" && store.activeTaskIsExecuting && store.islandIconTasks.map(\.id) == [active])
        try emit(AgentEvent(type: "upsert", id: active, agent: "WorkBuddy", status: .completed,
                            createdAt: date, sourceEvent: "Stop"))
        store.consumeEvents()
        check("ambient evidence: true completion retains ten-second feedback without an execution glyph", store.presentation == .medium &&
              store.activeTask?.id == active && !store.activeTaskIsExecuting && store.compactCountText.isEmpty && store.mediumStatusText == "已完成")
        date.addTimeInterval(10)
        store.refreshPresentation()
        check("ambient evidence: completion feedback expires despite unresolved history", store.presentation == .collapsed &&
              !store.hasLiveEvent && store.activeTask == nil && store.islandIconTasks.isEmpty && store.sortedTasks.count == 9)
        store.clearAllTasks()
    }

    private static func runCurrentActivityCountChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
        var date = Date()
        let store = TaskStore(now: { date })
        store.clearAllTasks()
        let active = UUID(), permission = UUID(), silent = UUID(), ambiguous = UUID(), chat = UUID()
        for (id, agent) in [(active, "Codex"), (permission, "Claude"), (silent, "豆包"),
                            (ambiguous, "Claude"), (chat, "Claude")] {
            try emit(AgentEvent(type: "upsert", id: id, agent: agent, status: .running,
                                createdAt: date, sourceEvent: "UserPromptSubmit"))
        }
        try emit(AgentEvent(type: "upsert", id: permission, status: .waiting,
                            createdAt: date, sourceEvent: "PermissionRequest"))
        store.consumeEvents()
        check("current count: five observed starts count as five activities, not approvals",
              store.compactCountText == "5" && store.waitingCount == 0)

        date.addTimeInterval(121)
        for (id, event) in [(silent, "DoubaoSilent"), (ambiguous, "AmbiguousTurn"), (chat, "ClaudeChatUnknown")] {
            try emit(AgentEvent(type: "upsert", id: id, status: .running, createdAt: date, sourceEvent: event))
        }
        try emit(AgentEvent(type: "upsert", id: active, status: .running, createdAt: date, sourceEvent: "PostToolUse"))
        store.consumeEvents()
        let before = store.tasks
        check("current count: unknown results drop out, the two started tasks still count",
              store.ongoingTasks.count == 5 && Set(store.currentActivityTasks.map(\.id)) == [active, permission] && store.compactCountText == "2")
        check("current count: unknown results do not inflate the icon stack or status",
              Set(store.islandIconTasks.map(\.id)) == [active, permission] && store.islandIconTasks.first?.id == active && store.mediumStatusText == "2 项正在执行")
        store.select(store.tasks.first { $0.id == permission }!)
        check("current count: a selected running permission check leads without becoming an approval",
              store.selectedTask?.id == permission && store.activeTask?.id == permission && store.waitingCount == 0 && store.compactCountText == "2")
        check("current count: all five records remain in hover history with unchanged raw states",
              store.sortedTasks.count == 5 && store.tasks == before)
        let reload = TaskStore(now: { date })
        check("current count: restart preserves five records and still counts the two running",
              reload.ongoingTasks.count == 5 && reload.compactCountText == "2")

        date.addTimeInterval(120.01)
        store.refreshPresentation()
        check("current count: two quiet minutes do not drop a started task", store.compactCountText == "2" && store.activeTaskIsExecuting == false)
        date.addTimeInterval(AgentActivityMotion.unresolvedLimit)
        store.refreshPresentation()
        check("current count: with nothing running the count is zero, no number or motion",
              store.compactCountText.isEmpty && store.currentActivityTasks.isEmpty && !store.activeTaskIsExecuting)
        check("current count: unresolved rows past the limit release the island and keep their history",
              store.presentation == .collapsed && store.islandIconTasks.isEmpty && store.sortedTasks.count == 5 && store.tasks == before)
        check("current count: restarting unresolved history cannot restore a live number",
              TaskStore(now: { date }).compactCountText.isEmpty)

        let second = UUID()
        for id in [active, second] {
            try emit(AgentEvent(type: "upsert", id: id, agent: "Codex", status: .running,
                                createdAt: date, sourceEvent: "PreToolUse"))
        }
        store.consumeEvents()
        date.addTimeInterval(10)
        store.refreshPresentation()
        store.select(store.tasks.first { $0.id == second }!)
        check("current count: two actual tasks from the same provider retain two icons and count",
              store.compactCountText == "2" && store.islandIconTasks.count == 2 && store.islandIconTasks.first?.id == second &&
              store.mediumStatusText == "2 项正在执行")
        store.clearAllTasks()
    }

    private static func runSizingRefreshChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
        var date = Date()
        let store = TaskStore(now: { date })
        store.clearAllTasks()
        let id = UUID()
        try emit(AgentEvent(type: "upsert", id: id, agent: "Codex", status: .running, createdAt: date, sourceEvent: "UserPromptSubmit"))
        store.consumeEvents()
        check("fresh real activity count starts at one", store.freshLiveTasks.count == 1)
        date.addTimeInterval(121)
        check("fresh activity expires even when first read bypasses sortedTasks", store.freshLiveTasks.isEmpty && store.liveTasks.count == 1)
        store.refreshPresentation()
        check("a quiet started task keeps its count and motion", store.presentation == .compact &&
              store.activeTask?.id == id && store.compactCountText == "1" && store.activeTaskIsExecuting &&
              store.tasks.first(where: { $0.id == id })?.status == .running)
        let waiting = UUID()
        try emit(AgentEvent(type: "upsert", id: waiting, agent: "WorkBuddy", status: .waiting, createdAt: date, sourceEvent: "Notification"))
        store.consumeEvents()
        check("explicit notification counts user attention", store.waitingCount == 1)
        date.addTimeInterval(121)
        check("waiting cache expires without needing another property read", store.waitingCount == 0)
        check("usage uses injected current calendar day and counts each retained turn once", store.todayAgentUsage.reduce(0) { $0 + $1.count } == store.tasks.filter { $0.updatedAt >= Calendar.autoupdatingCurrent.startOfDay(for: date) && $0.updatedAt <= date }.count)
        date = Calendar.autoupdatingCurrent.startOfDay(for: date).addingTimeInterval(86_401)
        check("usage cache resets across calendar midnight", store.todayAgentUsage.isEmpty)
        store.clearAllTasks()
        store.setAutomaticActivityWidth(true)
        var publications = 0
        let observation = store.$mediumWingWidth.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<10 { store.refreshPresentation() }
        check("unchanged automatic width does not publish on each poll", publications == 0)
        observation.cancel()
        store.setActivityWidth(200)
        check("manual size clears auto width override", store.mediumWingWidth == nil && !store.automaticActivityWidth)
        store.setAutomaticActivityWidth(true)
        check("auto mode restores measured width", store.mediumWingWidth != nil)
        // Let the size preview started by the settings calls run out first.
        date.addTimeInterval(7)
        store.refreshPresentation()
        store.refreshPresentation()
        let idleWidth = store.mediumWingWidth ?? 0
        try emit(AgentEvent(type: "upsert", id: UUID(), agent: "Codex", status: .running, createdAt: date, sourceEvent: "PreToolUse"))
        store.consumeEvents()
        store.refreshPresentation()
        let entered = store.mediumWingWidth ?? 0
        check("medium entry opens at its own width, not the idle one", entered < idleWidth)
        date.addTimeInterval(2)
        store.refreshPresentation()
        check("medium entry does not shrink again after opening", store.mediumWingWidth == entered)
        store.clearAllTasks()
    }

    private static func runButlerStoreChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
        var date = Date()
        let store = TaskStore(now: { date })
        store.clearAllTasks()
        let waiting = UUID(), running = UUID(), queued = UUID(), completed = UUID(), failed = UUID()
        for (id, status, age) in [(waiting, AgentTaskStatus.waiting, 100.0), (running, .running, 50.0),
                                  (queued, .queued, 10.0), (completed, .completed, 2.0), (failed, .failed, 1.0)] {
            try emit(AgentEvent(type: "upsert", id: id, agent: "Codex", status: status, createdAt: date.addingTimeInterval(-age)))
        }
        store.consumeEvents()
        check("active rows precede recent finished history", store.sortedTasks.map(\.id) == [waiting, queued, running, failed, completed])
        check("recent terminal tasks remain in hover list but not live counts", store.tasks.count == 5 && store.sortedTasks.count == 5 && store.liveTasks.count == 3)
        store.selectedTaskID = completed
        check("completed history remains selectable without displacing pending ambient task", store.selectedTask?.id == completed && store.activeTask?.id == waiting)
        check("icon stack leads with displayed task and excludes finished history", store.islandIconTasks.map(\.id) == [waiting, queued, running])
        date.addTimeInterval(86_401)
        store.refreshPresentation()
        check("24h retains admitted long tasks but ages out terminal history", store.sortedTasks.count == 3 && store.tasks.count == 5 && store.tasks.first { $0.id == running }?.status == .running)
        check("24h silence ends the count without actionable approval", store.waitingCount == 0 && store.ongoingTasks.count == 3 && store.compactCountText.isEmpty && store.presentation == .collapsed)
        try emit(AgentEvent(type: "upsert", id: running, agent: "Codex", status: .running, createdAt: date, sourceEvent: "PreToolUse"))
        store.consumeEvents()
        check("new real activity resumes a retained long task", store.sortedTasks.count == 3 && store.activeTask?.id == running && store.presentation == .compact)
        date.addTimeInterval(86_400)
        store.refreshPresentation()
        check("exactly 24h retains all admitted long tasks", store.sortedTasks.count == 3)
        date.addTimeInterval(0.01)
        store.refreshPresentation()
        check("greater than 24h does not end admitted tasks or invent a live count", store.sortedTasks.count == 3 && store.compactCountText.isEmpty)
        let reload = TaskStore(now: { date })
        check("reload preserves unresolved membership without executing stale tasks", reload.tasks == store.tasks && reload.ongoingTasks.count == 3 && !reload.activeTaskIsExecuting)
        store.clearAllTasks()

        let first = UUID(), second = UUID(), third = UUID()
        for (id, agent) in [(first, "Codex"), (second, "Codex"), (third, "WorkBuddy")] {
            try emit(AgentEvent(type: "upsert", id: id, agent: agent, status: .running, createdAt: date))
        }
        store.consumeEvents()
        date.addTimeInterval(11)
        store.select(store.tasks.first { $0.id == first }!)
        check("simultaneous tasks retain separate icons even for same provider", store.islandIconTasks.count == 3 && store.islandIconTasks.first?.id == first)
        store.select(store.tasks.first { $0.id == third }!)
        check("selecting a running task moves its icon to the front", store.islandIconTasks.first?.id == third && store.primaryAgentName == "WorkBuddy")
        try emit(AgentEvent(type: "upsert", id: third, status: .completed, createdAt: date))
        store.consumeEvents()
        date.addTimeInterval(11)
        store.refreshPresentation()
        check("finished task stays in list but leaves ambient icon stack", store.sortedTasks.count == 3 && store.islandIconTasks.count == 2 && !store.islandIconTasks.contains { $0.id == third })
        for id in [first, second] { try emit(AgentEvent(type: "upsert", id: id, status: .completed, createdAt: date)) }
        store.consumeEvents()
        date.addTimeInterval(11)
        store.refreshPresentation()
        check("all-finished recent history does not keep island open", store.sortedTasks.count == 3 && store.liveTasks.isEmpty && store.islandIconTasks.isEmpty && store.presentation == .collapsed)
        check("recent finished history survives app restart", TaskStore(now: { date }).sortedTasks.count == 3)
        date.addTimeInterval(86_400)
        store.refreshPresentation()
        check("finished history ages out without deleting saved tasks", store.sortedTasks.isEmpty && store.tasks.count == 3)
        store.clearAllTasks()
    }

    private static func runReleaseStoreChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
        var date = Date()
        let store = TaskStore(now: { date })
        store.clearAllTasks()
        store.setAutoPopOnEvent(true)
        store.setHeavyOnHover(true)
        let recentWaiting = UUID(), olderWaiting = UUID(), active = UUID(), queued = UUID(), obsolete = UUID()
        for (id, status, age) in [
            (recentWaiting, AgentTaskStatus.waiting, 60.0), (olderWaiting, .waiting, 120.0),
            (active, .running, 5.0), (queued, .queued, 10.0), (obsolete, .waiting, 86_400.01)
        ] {
            try emit(AgentEvent(type: "upsert", id: id, agent: "Codex", status: status,
                                requiresApproval: status == .waiting, createdAt: date.addingTimeInterval(-age)))
        }
        store.consumeEvents()
        check("release store: waiting rows sort newest first ahead of all active rows",
              store.sortedTasks.map(\.id) == [recentWaiting, olderWaiting, active, queued])
        check("release store: expired waiting rows do not contribute an approval counter",
              store.waitingCount == 2 && store.tasks.first { $0.id == obsolete }?.status == .waiting)
        store.selectedTaskID = obsolete
        check("release store: a hidden selected row cannot drive the detail or ambient island",
              store.selectedTask?.id == recentWaiting && store.activeTask?.id == recentWaiting)
        let tieA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let tieB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        for id in [tieB, tieA] {
            try emit(AgentEvent(type: "upsert", id: id, agent: "Claude", status: .running, createdAt: date))
        }
        store.consumeEvents()
        check("release store: equal activity timestamps have a deterministic task order",
              store.sortedTasks.filter { $0.id == tieA || $0.id == tieB }.map(\.id) == [tieA, tieB])
        let ended = UUID()
        try emit(AgentEvent(type: "upsert", id: ended, agent: "Codex", status: .completed, createdAt: date, sourceEvent: "Stop"))
        store.consumeEvents()
        check("release store: a new completion remains selectable as recent history",
              store.tasks.contains { $0.id == ended } && store.sortedTasks.contains { $0.id == ended } && !store.liveTasks.contains { $0.id == ended })

        // A source may retain a raw running state after it can no longer
        // prove the turn is live. It must not outrank a newly finished row
        // before the UI groups both rows under 已结束.
        let untracked = UUID()
        try emit(AgentEvent(type: "upsert", id: untracked, agent: "豆包", status: .running,
                            createdAt: date.addingTimeInterval(-30), sourceEvent: "DoubaoSilent"))
        let justFinished = UUID()
        try emit(AgentEvent(type: "upsert", id: justFinished, agent: "Codex", status: .completed,
                            createdAt: date.addingTimeInterval(0.1), sourceEvent: "Stop"))
        store.consumeEvents()
        let visibleItems = store.sortedTasks.map { task in
            TaskVisualItem(task: task,
                           state: TaskVisualState.resolve(task,
                                                          displayedStatus: store.displayedStatus(for: task),
                                                          needsAttention: store.needsUserAttention(task)))
        }
        let endedOrder = TaskVisualSection.grouped(visibleItems)
            .first { $0.group == .ended }?.items.map(\.id) ?? []
        check("release store: newly finished rows lead ended history over stale unknown rows",
              endedOrder.first == justFinished && endedOrder.contains(untracked))
        date.addTimeInterval(86_401)
        store.refreshPresentation()
        check("release store: unresolved tasks persist while terminal and unadopted history ages out",
              store.sortedTasks.count == 6 && store.ongoingTasks.count == 6 && store.waitingCount == 0 && store.presentation == .collapsed && store.compactCountText.isEmpty &&
              store.tasks.first { $0.id == active }?.status == .running && store.tasks.first { $0.id == olderWaiting }?.status == .waiting)
        store.clearAllTasks()

        date = Date()
        let toolTaskID = UUID()
        func toolCallback(_ name: String, id: String) throws {
            date.addTimeInterval(0.1)
            var event = AgentEvent(type: "upsert", id: toolTaskID, agent: "Claude", status: .running,
                                   createdAt: date, sourceEvent: name)
            event.toolStepID = id
            event.toolLabel = "读取文件"
            try emit(event)
            store.consumeEvents()
        }
        try toolCallback("PreToolUse", id: "release-real-tool-a")
        check("release store: a received pre-tool event is not counted as an executed step",
              store.tasks.first { $0.id == toolTaskID }?.returnedToolSteps.isEmpty == true)
        try toolCallback("PostToolUse", id: "release-real-tool-a")
        try toolCallback("PostToolUse", id: "release-real-tool-a")
        check("release store: duplicate real callbacks count one returned execution",
              store.tasks.first { $0.id == toolTaskID }?.returnedToolSteps.count == 1)
        try toolCallback("PreToolUse", id: "release-real-tool-b")
        try toolCallback("PostToolUseFailure", id: "release-real-tool-b")
        try toolCallback("PreToolUse", id: "release-real-tool-c")
        check("release store: returned-step count includes observed failures and excludes pending tools",
              store.tasks.first { $0.id == toolTaskID }?.returnedToolSteps.count == 2 &&
              store.tasks.first { $0.id == toolTaskID }?.returnedToolSteps.first?.state == .failed &&
              store.tasks.first { $0.id == toolTaskID }?.toolSteps.count == 3)
        let ledgerReload = TaskStore(now: { date })
        check("release store: exact tool history survives an atomic restart snapshot",
              ledgerReload.tasks.first { $0.id == toolTaskID }?.toolSteps == store.tasks.first { $0.id == toolTaskID }?.toolSteps)
        store.clearAllTasks()

        // Reproduce the observed 23:41:09 permission check followed by a tool
        // return 13.692s later: a hook callback alone is not a visible prompt.
        let permissionOnly = UUID()
        try emit(AgentEvent(type: "upsert", id: permissionOnly, agent: "Claude", status: .running,
                            requiresApproval: false, createdAt: date, sourceEvent: "PreToolUse"))
        store.consumeEvents()
        date.addTimeInterval(11)
        store.refreshPresentation()
        try emit(AgentEvent(type: "upsert", id: permissionOnly, agent: "Claude", status: .waiting,
                            requiresApproval: true, createdAt: date, sourceEvent: "PermissionRequest"))
        store.consumeEvents()
        if let task = store.tasks.first(where: { $0.id == permissionOnly }) {
            check("permission check without a live request never counts as a user confirmation",
                  !store.needsUserAttention(task) && store.waitingCount == 0 && store.presentation == .compact &&
                  store.mediumStatusText == "在 App 里处理")
            check("permission check details do not tell the user to find a nonexistent prompt",
                  store.currentStepText(for: task).contains("正在确认权限") &&
                  store.statusSummary(for: .claude).contains("在 App 里处理"))
        }
        let permissionReload = TaskStore(now: { date })
        check("restarting cannot turn a bare permission check into a user prompt",
              permissionReload.waitingCount == 0 && permissionReload.mediumStatusText == "在 App 里处理")
        date.addTimeInterval(13.692)
        try emit(AgentEvent(type: "upsert", id: permissionOnly, agent: "Claude", status: .running,
                            requiresApproval: false, createdAt: date, sourceEvent: "PostToolUse"))
        store.consumeEvents()
        check("real tool return clears permission checking without another attention pulse",
              store.waitingCount == 0 && store.activeTask?.status == .running && store.presentation == .compact)
        date.addTimeInterval(1)
        try emit(AgentEvent(type: "upsert", id: permissionOnly, agent: "Codex", status: .waiting,
                            requiresApproval: true, createdAt: date, sourceEvent: "Notification"))
        store.consumeEvents()
        check("an explicit provider prompt notification still attracts user attention",
              store.waitingCount == 1 && store.presentation == .medium && store.mediumStatusText == "等你批准")
        store.clearAllTasks()

        // Codex asks in its own card on PermissionRequest and sends no hook once
        // the user answers there; its rollout shows the turn moving on.
        date = Date()
        let codexRaw = UUID().uuidString.lowercased()
        let codexSession = CodexRollout.sessionDigest(rawSessionID: codexRaw)
        let codexTask = UUID()
        try emit(AgentEvent(type: "upsert", id: codexTask, agent: "Codex", status: .waiting, requiresApproval: true,
                            createdAt: date, sourceEvent: "PermissionRequest", sessionID: codexSession))
        store.consumeEvents()
        check("Codex approval waits briefly before prompting",
              store.waitingCount == 0 && store.presentation == .compact)
        date.addTimeInterval(3)
        store.refreshPresentation()
        if let task = store.tasks.first(where: { $0.id == codexTask }) {
            check("Codex approval prompts on the island and points to Codex",
                  store.needsUserAttention(task) && store.waitingCount == 1 && store.presentation == .medium &&
                  store.approvalSurfaceText(for: task) == "在 Codex 里批准" && store.approvalRequest(for: task) == nil)
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let folder = LinglongtaiPaths.applicationSupport.appendingPathComponent("fixture-codex-sessions")
            .appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rollout = folder.appendingPathComponent("rollout-2026-10-16T08-00-00-\(codexRaw).jsonl")
        func rolloutLine(_ offset: TimeInterval, _ type: String, _ payload: String?) -> String {
            let body = payload.map { #","payload":{"type":"\#($0)","name":"exec","input":"PRIVATE_FIXTURE"}"# } ?? ""
            return #"{"timestamp":"\#(stamp.string(from: date.addingTimeInterval(offset - 3)))","type":"\#(type)"\#(body)}"# + "\n"
        }
        try (rolloutLine(0.3, "token_usage_record", nil) + rolloutLine(1.5, "event_msg", "item_completed")).write(to: rollout, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: rollout.path)
        store.resolveCodexApprovalsAnsweredInApp()
        check("Codex bookkeeping while its card is shown does not count as an answer",
              store.tasks.first(where: { $0.id == codexTask })?.status == .waiting && store.waitingCount == 1)
        date.addTimeInterval(9)
        // A blocked approval: Codex keeps polling the blocked cell.
        try (rolloutLine(0.3, "token_usage_record", nil) + rolloutLine(5, "response_item", "function_call") +
             rolloutLine(6, "response_item", "function_call_output") + rolloutLine(7, "response_item", "custom_tool_call_output")).write(to: rollout, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: rollout.path)
        store.resolveCodexApprovalsAnsweredInApp()
        check("Codex polling a cell blocked on approval is not an answer",
              store.tasks.first(where: { $0.id == codexTask })?.status == .waiting && store.waitingCount == 1)
        date.addTimeInterval(3)
        try (rolloutLine(0.3, "token_usage_record", nil) + rolloutLine(10, "response_item", "custom_tool_call")).write(to: rollout, atomically: true, encoding: .utf8)
        // The fixture clock is not the file system's; stamp the write like a live one.
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: rollout.path)
        store.resolveCodexApprovalsAnsweredInApp()
        check("an approval answered in Codex resumes the running state and its motion",
              store.tasks.first(where: { $0.id == codexTask })?.status == .running && store.waitingCount == 0 &&
              store.activeTask?.id == codexTask && store.activeTaskIsExecuting)
        try? FileManager.default.removeItem(at: rollout)
        store.clearAllTasks()

        date = Date()
        let loggedTask = UUID()
        let loggedRaw = UUID().uuidString.lowercased()
        try emit(AgentEvent(type: "upsert", id: loggedTask, agent: "Codex", status: .waiting, requiresApproval: true,
                            createdAt: date, sourceEvent: "PermissionRequest", sessionID: CodexRollout.sessionDigest(rawSessionID: loggedRaw)))
        store.consumeEvents()
        date.addTimeInterval(4)
        let logParts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let logFolder = LinglongtaiPaths.applicationSupport.appendingPathComponent("fixture-codex-logs")
            .appendingPathComponent(String(format: "%04d/%02d/%02d", logParts.year!, logParts.month!, logParts.day!))
        try FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        let logStamp = ISO8601DateFormatter()
        logStamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let appLog = logFolder.appendingPathComponent("codex-desktop-fixture.log")
        try (logStamp.string(from: date.addingTimeInterval(-3)) + " info [electron-message-handler] [desktop-notifications] received approval conversationId=\(loggedRaw) kind=commandExecution rendererWindowFocused=false requestId=7\n" +
             logStamp.string(from: date) + " info [electron-message-handler] Sending server response id=7 method=item/commandExecution/requestApproval rendererWindowFocused=true response={\"decision\":\"accept\"}\n")
            .write(to: appLog, atomically: true, encoding: .utf8)
        store.resolveCodexApprovalsAnsweredInApp()
        check("an approval answered in the Codex app is picked up from Codex's own log at once",
              store.tasks.first(where: { $0.id == loggedTask })?.status == .running && store.waitingCount == 0)
        try? FileManager.default.removeItem(at: appLog)
        store.clearAllTasks()

        // Island-side approval fixtures were intentionally removed. A
        // PermissionRequest without a provider Notification is not actionable.
        date = Date()
        let permissionTaskID = UUID()
        try emit(AgentEvent(type: "upsert", id: permissionTaskID, agent: "Claude", status: .waiting,
                            requiresApproval: true, createdAt: date, sourceEvent: "PermissionRequest"))
        store.consumeEvents()
        if let task = store.tasks.first(where: { $0.id == permissionTaskID }) {
            check("release store: observer-only PermissionRequest never creates a review request",
                  store.approvalRequest(for: task) == nil && store.reviewingApproval == nil &&
                  !store.needsUserAttention(task) && store.waitingCount == 0 &&
                  store.mediumStatusText == "在 App 里处理")
        }
        check("release store: approval support is limited to Claude Code and Codex",
              ApprovalRelay.supports(.claude) && ApprovalRelay.supports(.codex) && !ApprovalRelay.supports(.workBuddy))
        store.clearAllTasks()
    }

    private static func runPresentationRevisionChecks(
        check: (String, Bool) -> Void,
        emit: (AgentEvent) throws -> Void
    ) throws {
        let origin = Date(timeIntervalSince1970: 1_900_000_000)
        var currentTime = origin
        let store = TaskStore(now: { currentTime })
        store.setAutoPopOnEvent(true)
        store.setHeavyOnHover(true)

        func jump(to seconds: TimeInterval) {
            currentTime = origin.addingTimeInterval(seconds)
            store.refreshPresentation()
        }
        func send(_ id: UUID, provider: AgentKind = .codex, name: String,
                  status: AgentTaskStatus, type: String = "upsert") throws {
            try emit(AgentEvent(type: type, id: id, agent: provider.displayName,
                                title: "Acceptance lifecycle", status: status,
                                requiresApproval: status == .waiting, createdAt: currentTime,
                                sourceEvent: name))
            store.consumeEvents()
        }

        let longTask = UUID()
        try send(longTask, name: "UserPromptSubmit", status: .running)
        check("new live task starts the ten-second medium presentation", store.presentation == .medium)
        jump(to: 9.9)
        check("initial task remains medium at 9.9 seconds", store.presentation == .medium)
        jump(to: 10)
        check("initial task becomes compact at exactly ten seconds", store.presentation == .compact && store.liveTasks.count == 1)

        let beforeHover = store.tasks
        store.samplePointer(inside: true, at: 100)
        store.samplePointer(inside: true, at: 100.2)
        check("hover expands a compact live task to detail", store.presentation == .heavy)
        store.samplePointer(inside: false, at: 102)
        store.samplePointer(inside: false, at: 102.2)
        check("leaving detail restores compact without changing task data", store.presentation == .compact && store.tasks == beforeHover)

        jump(to: 1_800)
        let silentTask = store.tasks.first { $0.id == longTask }
        check("a thirty-minute quiet task still counts as one running task",
              store.presentation == .compact && store.liveTasks.map(\.id) == [longTask] &&
              silentTask?.status == .running && store.compactCountText == "1" && store.activeTask?.id == longTask && store.activeTaskIsExecuting)
        check("a quiet task shows its real status without inventing an ending",
              silentTask.map { store.displayedStatus(for: $0) == "处理中" } == true &&
              !store.statusSummary(for: .codex).contains("结果未知"))
        jump(to: 1_801)
        try send(longTask, name: "PreToolUse", status: .running)
        check("ordinary tool activity does not reopen medium for a long task", store.presentation == .compact)

        jump(to: 1_811)
        try send(longTask, name: "UserPromptSubmit", status: .running)
        check("a new prompt starts a new medium interval even while the session is running", store.presentation == .medium)
        jump(to: 1_819)
        try send(longTask, name: "PostToolUse", status: .running)
        jump(to: 1_820.9)
        check("ordinary tools leave the original prompt deadline intact at 9.9 seconds", store.presentation == .medium)
        jump(to: 1_821)
        check("ordinary tools cannot extend the prompt deadline past ten seconds", store.presentation == .compact)

        jump(to: 1_822)
        try send(longTask, provider: .claude, name: "PermissionRequest", status: .waiting)
        check("a bare permission check does not claim that the user must confirm",
              store.presentation == .compact && store.waitingCount == 0 && store.activeTask?.requiresApproval == true)
        jump(to: 1_831.9)
        check("a bare permission check stays compact while the provider resolves it", store.presentation == .compact)
        jump(to: 1_832)
        check("a bare permission check remains visible as a non-actionable waiting task",
              store.presentation == .compact && store.waitingCount == 0 && store.liveTasks.first?.status == .waiting)
        jump(to: 3_622)
        check("a thirty-minute permission check remains visible without claiming actionable approval",
              store.presentation == .compact && store.waitingCount == 0 && store.activeTask?.id == longTask && store.compactCountText == "1" &&
              store.liveTasks.first?.status == .waiting && store.liveTasks.first?.requiresApproval == true)
        jump(to: 3_623)
        try send(longTask, name: "PostToolUse", status: .running)
        check("tool resumption clears approval without reopening medium", store.presentation == .compact && store.waitingCount == 0)

        jump(to: 3_624)
        try send(longTask, name: "Stop", status: .completed)
        check("a real long-task ending displays its terminal state", store.presentation == .medium &&
              store.liveTasks.isEmpty && store.activeTask?.id == longTask && store.mediumStatusText == "已完成")
        jump(to: 3_633.9)
        check("terminal feedback remains medium at 9.9 seconds", store.presentation == .medium)
        jump(to: 3_634)
        check("an ended last task collapses at ten seconds", store.presentation == .collapsed && !store.hasLiveEvent)
        jump(to: 5_424)
        check("terminal history remains terminal after thirty minutes",
              store.tasks.first(where: { $0.id == longTask }).map { store.displayedStatus(for: $0) == "本轮已结束" } == true)

        let firstConcurrent = UUID(), remainingConcurrent = UUID()
        jump(to: 6_000)
        try send(firstConcurrent, name: "UserPromptSubmit", status: .running)
        jump(to: 6_001)
        try send(remainingConcurrent, provider: .workBuddy, name: "UserPromptSubmit", status: .running)
        jump(to: 6_011)
        check("multiple active tasks settle into one compact island", store.presentation == .compact && store.liveTasks.count == 2)
        jump(to: 6_012)
        try send(firstConcurrent, name: "Stop", status: .completed)
        check("one terminal event highlights completion while another task remains active",
              store.presentation == .medium && store.liveTasks.map(\.id) == [remainingConcurrent] &&
              store.activeTask?.id == firstConcurrent && store.mediumStatusText == "已完成 · 1 项正在执行")
        jump(to: 6_021.9)
        check("mixed terminal feedback remains medium at 9.9 seconds", store.presentation == .medium)
        jump(to: 6_022)
        check("mixed terminal feedback returns to the remaining compact task at ten seconds",
              store.presentation == .compact && store.activeTask?.id == remainingConcurrent && store.hasLiveEvent)
        jump(to: 6_023)
        try send(remainingConcurrent, provider: .workBuddy, name: "StopFailure", status: .failed)
        check("a real failure receives terminal feedback", store.presentation == .medium && store.activeTask?.status == .failed)
        jump(to: 6_033)
        check("the final failed task collapses after terminal feedback", store.presentation == .collapsed && store.liveTasks.isEmpty)

        let closedSession = UUID()
        jump(to: 6_100)
        try send(closedSession, name: "UserPromptSubmit", status: .running)
        jump(to: 7_900)
        try send(closedSession, name: "SessionEnd", status: .cancelled, type: "end-session")
        check("SessionEnd of a long active task receives the same terminal feedback",
              store.presentation == .medium && store.activeTask?.id == closedSession && store.mediumStatusText == "会话已关闭")
        jump(to: 7_909.9)
        check("SessionEnd feedback stays visible at 9.9 seconds", store.presentation == .medium)
        jump(to: 7_910)
        check("SessionEnd feedback collapses at ten seconds", store.presentation == .collapsed && !store.hasLiveEvent)

        let beforeCalibration = store.tasks
        let connectionsBeforeCalibration = store.connections
        let eventLogBeforeCalibration = try Data(contentsOf: LinglongtaiPaths.events)
        let snapshotBeforeCalibration = try Data(contentsOf: LinglongtaiPaths.state)
        let commandsBeforeCalibration = try Data(contentsOf: LinglongtaiPaths.commands)
        let adjustments: [(String, () -> Void)] = [
            ("height", { store.setNotchOffset(-6) }),
            ("notch width", { store.setNotchWidthAdjustment(24) }),
            ("activity width", { store.setActivityWidth(260) })
        ]
        store.previewCalibration(.medium)
        store.showTaskDetails()
        check("opening task details from the menu ends calibration instead of being overridden",
              store.calibrationPreview == nil && store.presentation == .heavy)
        store.resetInteraction()
        for (index, adjustment) in adjustments.enumerated() {
            let start = 8_100 + Double(index) * 10
            jump(to: start)
            adjustment.1()
            check("\(adjustment.0) adjustment starts a labeled medium calibration preview",
                  store.presentation == .medium && store.calibrationPreview == .medium && store.mediumStatusText == "中态预览")
            jump(to: start + 5.9)
            check("\(adjustment.0) calibration remains visible at 5.9 seconds", store.calibrationPreview == .medium && store.presentation == .medium)
            jump(to: start + 6)
            check("\(adjustment.0) calibration ends at exactly six seconds", store.calibrationPreview == nil && store.presentation == .collapsed)
        }
        check("all three calibration controls accept independent values",
              store.notchOffset == -6 && store.notchWidthAdjustment == 24 && store.activityWidth == 260)
        check("activity slider explicitly selects manual sizing and clears content override",
              !store.automaticActivityWidth && store.mediumWingWidth == nil)
        let manualNarrow = IslandMetrics(activityWidth: 200, mediumWingWidth: store.mediumWingWidth).size(for: .medium)
        let manualWide = IslandMetrics(activityWidth: 300, mediumWingWidth: store.mediumWingWidth).size(for: .medium)
        check("manual activity width reaches actual medium geometry", manualWide.width > manualNarrow.width)
        store.setAutomaticActivityWidth(true)
        check("automatic sizing can be restored without changing task data", store.automaticActivityWidth && store.mediumWingWidth != nil && store.tasks == beforeCalibration)

        for (index, preview) in [TaskStore.Presentation.compact, .medium].enumerated() {
            let start = 8_200 + Double(index) * 10
            jump(to: start)
            store.previewCalibration(preview)
            check("explicit \(preview.rawValue) preview uses the selected presentation", store.presentation == preview && store.calibrationPreview == preview)
            jump(to: start + 5.9)
            check("explicit \(preview.rawValue) preview lasts 5.9 seconds", store.presentation == preview && store.calibrationPreview == preview)
            jump(to: start + 6)
            check("explicit \(preview.rawValue) preview ends at six seconds", store.calibrationPreview == nil && store.presentation == .collapsed)
        }

        jump(to: 8_240)
        store.setActivityWidth(280)
        jump(to: 8_245)
        store.setNotchOffset(8)
        jump(to: 8_246)
        check("another adjustment renews the calibration preview from the latest edit", store.calibrationPreview == .medium)
        jump(to: 8_250.9)
        check("renewed calibration remains visible for 5.9 seconds", store.calibrationPreview == .medium)
        jump(to: 8_251)
        check("renewed calibration ends six seconds after the latest edit", store.calibrationPreview == nil && store.presentation == .collapsed)
        jump(to: 8_270)
        store.resetCalibration()
        check("reset restores height zero, notch width zero and activity width 228",
              store.notchOffset == 0 && store.notchWidthAdjustment == 0 && store.activityWidth == 228 && store.automaticActivityWidth && store.calibrationPreview == .medium)
        jump(to: 8_275.9)
        check("reset also exposes a 5.9-second preview", store.calibrationPreview == .medium)
        jump(to: 8_276)
        check("reset preview expires at six seconds", store.calibrationPreview == nil && store.presentation == .collapsed)
        check("calibration never creates or modifies real tasks or connection evidence",
              store.tasks == beforeCalibration && store.connections == connectionsBeforeCalibration && !store.demoPreviewActive)
        let eventLogAfterCalibration = try Data(contentsOf: LinglongtaiPaths.events)
        let snapshotAfterCalibration = try Data(contentsOf: LinglongtaiPaths.state)
        let commandsAfterCalibration = try Data(contentsOf: LinglongtaiPaths.commands)
        check("calibration never writes task events, snapshots or agent commands",
              eventLogAfterCalibration == eventLogBeforeCalibration && snapshotAfterCalibration == snapshotBeforeCalibration &&
              commandsAfterCalibration == commandsBeforeCalibration)

        let calibratedLiveTask = UUID()
        jump(to: 8_300)
        try send(calibratedLiveTask, name: "UserPromptSubmit", status: .running)
        jump(to: 8_310)
        let liveBeforeCalibration = store.tasks
        jump(to: 8_320)
        store.previewCalibration(.medium)
        jump(to: 8_326)
        check("calibration expiration returns to an active compact task without changing it",
              store.presentation == .compact && store.tasks == liveBeforeCalibration && store.activeTask?.id == calibratedLiveTask)
        jump(to: 8_340)
        try send(calibratedLiveTask, name: "UserPromptSubmit", status: .running)
        jump(to: 8_341)
        store.previewCalibration(.compact)
        jump(to: 8_347)
        check("compact calibration restores a still-active medium deadline", store.calibrationPreview == nil && store.presentation == .medium)
        jump(to: 8_350)
        check("calibration does not extend the underlying ten-second task deadline", store.presentation == .compact)

        jump(to: 8_360)
        try send(calibratedLiveTask, name: "UserPromptSubmit", status: .running)
        let beforeDismiss = store.tasks
        if let task = store.tasks.first(where: { $0.id == calibratedLiveTask }) { store.dismissTask(task) }
        check("dismissing the last active row removes its local attention pulse",
              store.presentation == .collapsed && !store.hasLiveEvent && store.tasks == beforeDismiss.filter { $0.id != calibratedLiveTask })
        jump(to: 8_370)
        try send(UUID(), name: "UserPromptSubmit", status: .running)
        store.clearAllTasks()
        check("clearing all local rows leaves no residual event presentation",
              store.tasks.isEmpty && !store.hasLiveEvent && store.presentation == .collapsed)
        let commandsAfterDismiss = try Data(contentsOf: LinglongtaiPaths.commands)
        check("local dismissal and clearing never send stop commands to agents", commandsAfterDismiss == commandsBeforeCalibration)
    }

    private static func runTrackedHookRevisionChecks(
        check: (String, Bool) -> Void,
        emit: (AgentEvent) throws -> Void
    ) throws {
        var currentTime = Date(timeIntervalSince1970: 1_910_000_000)
        let store = TaskStore(now: { currentTime })
        var tracker = HookTurnTracker()

        func map(_ provider: AgentKind, _ name: String, session: String, turn: String? = nil) throws -> AgentEvent? {
            currentTime.addTimeInterval(1)
            var payload: [String: Any] = ["hook_event_name": name, "session_id": session]
            if let turn { payload["turn_id"] = turn }
            return HookEventMapper.map(provider: provider, payload: try JSONSerialization.data(withJSONObject: payload), now: currentTime)
        }
        @discardableResult
        func consume(_ mapped: AgentEvent) throws -> [AgentEvent] {
            let events = tracker.route(mapped)
            for event in events { try emit(event) }
            store.consumeEvents()
            return events
        }
        @discardableResult
        func feed(_ provider: AgentKind, _ name: String, session: String, turn: String? = nil) throws -> [AgentEvent] {
            guard let mapped = try map(provider, name, session: session, turn: turn) else {
                check("tracker integration can map \(provider.rawValue) \(name)", false)
                return []
            }
            return try consume(mapped)
        }
        func task(_ id: UUID) -> AgentTask? { store.tasks.first { $0.id == id } }

        let nativeSession = "TRACKER_PRIVATE_native-session"
        let nativeFirstEvents = try feed(.codex, "UserPromptSubmit", session: nativeSession, turn: "TRACKER_PRIVATE_turn-a")
        let nativeSecondEvents = try feed(.codex, "UserPromptSubmit", session: nativeSession, turn: "TRACKER_PRIVATE_turn-b")
        guard let nativeFirst = nativeFirstEvents.first?.id, let nativeSecond = nativeSecondEvents.first?.id else {
            check("native tracker fixtures produce task identities", false)
            return
        }
        check("tracker and store retain two native turns in the same provider session",
              nativeFirst != nativeSecond && store.tasks.count == 2 &&
              task(nativeFirst)?.status == .running && task(nativeSecond)?.status == .running)
        try feed(.codex, "Stop", session: nativeSession, turn: "TRACKER_PRIVATE_turn-a")
        check("stopping one native turn leaves the other native turn running",
              task(nativeFirst)?.status == .completed && task(nativeSecond)?.status == .running)

        let unrelated = try feed(.codex, "UserPromptSubmit", session: "TRACKER_PRIVATE_other-session", turn: "TRACKER_PRIVATE_other-turn")
        let otherProvider = try feed(.claude, "UserPromptSubmit", session: nativeSession, turn: "TRACKER_PRIVATE_turn-b")
        guard let unrelatedID = unrelated.first?.id, let otherProviderID = otherProvider.first?.id else {
            check("session isolation fixtures produce task identities", false)
            return
        }
        let unrelatedBefore = task(unrelatedID), otherProviderBefore = task(otherProviderID)
        try feed(.codex, "SessionEnd", session: nativeSession)
        check("SessionEnd closes only active turns from its matching provider and session",
              task(nativeFirst)?.status == .completed && task(nativeSecond)?.status == .cancelled &&
              task(nativeSecond)?.sourceEvent == "SessionEnd" &&
              task(unrelatedID) == unrelatedBefore && task(otherProviderID) == otherProviderBefore)

        let fallbackSession = "TRACKER_PRIVATE_sequential-fallback"
        let fallbackFirstEvents = try feed(.workBuddy, "UserPromptSubmit", session: fallbackSession)
        guard let fallbackFirst = fallbackFirstEvents.first?.id else {
            check("first fallback round has an identity", false)
            return
        }
        try feed(.workBuddy, "Stop", session: fallbackSession)
        let fallbackSecondEvents = try feed(.workBuddy, "UserPromptSubmit", session: fallbackSession)
        guard let fallbackSecond = fallbackSecondEvents.first?.id else {
            check("second fallback round has an identity", false)
            return
        }
        check("sequential fallback rounds remain separate rows with independent identities",
              fallbackFirst != fallbackSecond && task(fallbackFirst)?.status == .completed &&
              task(fallbackSecond)?.status == .running &&
              store.tasks.filter { $0.sessionID == fallbackSecondEvents.first?.sessionID }.count == 2)
        try feed(.workBuddy, "Stop", session: fallbackSession)

        let upgradedSession = "TRACKER_PRIVATE_native-upgrade"
        let anonymousEvents = try feed(.claude, "UserPromptSubmit", session: upgradedSession)
        guard let anonymousID = anonymousEvents.first?.id, let anonymousTask = task(anonymousID) else {
            check("anonymous upgrade fixture has a stored row", false)
            return
        }
        store.select(anonymousTask)
        let countBeforeUpgrade = store.tasks.count
        let upgradedEvents = try feed(.claude, "PreToolUse", session: upgradedSession, turn: "TRACKER_PRIVATE_late-native-turn")
        guard let upgraded = upgradedEvents.first, let upgradedID = upgraded.id else {
            check("native upgrade has a routed event", false)
            return
        }
        check("replacesTaskID upgrades the anonymous row without leaving a duplicate",
              upgraded.replacesTaskID == anonymousID && upgradedID != anonymousID &&
              task(anonymousID) == nil && task(upgradedID)?.sourceEvent == "PreToolUse" &&
              store.tasks.count == countBeforeUpgrade && store.selectedTaskID == upgradedID)

        let overlappingSession = "TRACKER_PRIVATE_overlapping-fallback"
        let overlappingFirst = try feed(.codex, "UserPromptSubmit", session: overlappingSession)
        let overlappingSecond = try feed(.codex, "UserPromptSubmit", session: overlappingSession)
        guard let overlappingFirstID = overlappingFirst.first?.id,
              let overlappingSecondID = overlappingSecond.first?.id else {
            check("overlapping fallback fixtures produce independent rows", false)
            return
        }
        check("overlapping fallback prompts preserve both rows and surface ambiguity",
              overlappingFirstID != overlappingSecondID && overlappingSecond.contains { $0.type == "ambiguous-turn" } &&
              task(overlappingFirstID)?.status == .running && task(overlappingSecondID)?.status == .running)
        let firstBeforeAmbiguousStop = task(overlappingFirstID), secondBeforeAmbiguousStop = task(overlappingSecondID)
        let ambiguousStop = try feed(.codex, "Stop", session: overlappingSession)
        check("an ambiguous Stop cannot complete either overlapping task",
              ambiguousStop.count == 1 && ambiguousStop.first?.type == "ambiguous-turn" &&
              task(overlappingFirstID) == firstBeforeAmbiguousStop && task(overlappingSecondID) == secondBeforeAmbiguousStop)
        check("ambiguous turns show an unknown result and are not counted as running",
              [overlappingFirstID, overlappingSecondID].allSatisfy { id in
                  guard let row = task(id) else { return false }
                  return row.sourceEvent == "AmbiguousTurn" && store.displayedStatus(for: row) == "结果未知" &&
                      store.liveTasks.contains { $0.id == id } && !store.currentActivityTasks.contains { $0.id == id }
              })
        let unrelatedBeforeAmbiguousEnd = task(unrelatedID)
        try feed(.codex, "SessionEnd", session: overlappingSession)
        check("explicit SessionEnd closes both ambiguous turns without touching other sessions",
              task(overlappingFirstID)?.status == .cancelled && task(overlappingSecondID)?.status == .cancelled &&
              task(unrelatedID) == unrelatedBeforeAmbiguousEnd)

        guard let legacyUpgrade = try map(.workBuddy, "PreToolUse", session: "TRACKER_PRIVATE_legacy-session", turn: "TRACKER_PRIVATE_legacy-native-turn"),
              let legacyID = legacyUpgrade.legacySessionID, let migratedID = legacyUpgrade.id else {
            check("legacy migration fixture exposes old and new identities", false)
            return
        }
        try emit(AgentEvent(type: "upsert", id: legacyID, agent: AgentKind.workBuddy.displayName,
                            title: "Acceptance legacy row", status: .running, progress: 0.75,
                            createdAt: currentTime.addingTimeInterval(-1)))
        store.consumeEvents()
        if let legacyTask = task(legacyID) { store.select(legacyTask) }
        let countBeforeMigration = store.tasks.count
        try consume(legacyUpgrade)
        check("legacySessionID migrates the old row in place and preserves selection",
              legacyID != migratedID && task(legacyID) == nil && task(migratedID)?.sourceEvent == "PreToolUse" &&
              task(migratedID)?.sessionID == legacyUpgrade.sessionID && task(migratedID)?.turnID == legacyUpgrade.turnID &&
              task(migratedID)?.progressKnown == false && store.tasks.count == countBeforeMigration && store.selectedTaskID == migratedID)

        let reloaded = TaskStore(now: { currentTime })
        check("tracker-derived rows survive the production snapshot reload",
              reloaded.tasks == store.tasks && reloaded.connections == store.connections)
        let eventLog = try String(contentsOf: LinglongtaiPaths.events, encoding: .utf8)
        let snapshot = try String(contentsOf: LinglongtaiPaths.state, encoding: .utf8)
        let trackerJSON = String(decoding: try JSONEncoder().encode(tracker), as: UTF8.self)
        check("tracker, event log and snapshot retain only hashed session and turn identifiers",
              [eventLog, snapshot, trackerJSON].allSatisfy { !$0.contains("TRACKER_PRIVATE_") })
    }
}
