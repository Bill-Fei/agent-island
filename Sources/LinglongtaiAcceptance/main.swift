import Foundation
import LinglongtaiShared

@main
struct LinglongtaiAcceptance {
    static func main() {
        var checks = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            checks += 1
            guard condition() else {
                fputs("FAIL: \(name)\n", stderr)
                exit(1)
            }
            print("PASS: \(name)")
        }

        var state = IslandInteraction()
        state.samplePointer(inside: true, at: 0)
        state.samplePointer(inside: true, at: 0.199)
        check("hover does not open before 200 milliseconds", !state.isHovering)
        state.samplePointer(inside: true, at: 0.2)
        check("hover opens at exactly 200 milliseconds", state.isHovering)
        for index in 0...10 { state.samplePointer(inside: false, at: 2 + Double(index) * 0.05) }
        check("repeated outside samples collapse", !state.isHovering)
        check("idle returns to notch", state.presentation(hasLiveEvent: false, autoPop: true, hoverEnabled: true) == .collapsed)
        check("live task returns to medium", state.presentation(hasLiveEvent: true, autoPop: true, hoverEnabled: true) == .medium)

        var idle = IslandInteraction()
        for index in 0...24 { idle.samplePointer(inside: true, at: Double(index) / 120) }
        check("idle hover opens detail", idle.presentation(hasLiveEvent: false, autoPop: true, hoverEnabled: true) == .heavy)

        var briefExit = IslandInteraction()
        briefExit.samplePointer(inside: true, at: 0)
        briefExit.samplePointer(inside: true, at: 0.2)
        briefExit.samplePointer(inside: false, at: 2)
        briefExit.samplePointer(inside: true, at: 2.1)
        check("brief boundary exit does not flicker", briefExit.isHovering)
        var cancelledDwell = IslandInteraction()
        cancelledDwell.samplePointer(inside: true, at: 0)
        cancelledDwell.samplePointer(inside: false, at: 0.199)
        cancelledDwell.samplePointer(inside: true, at: 2)
        cancelledDwell.samplePointer(inside: true, at: 2.199)
        check("leaving before deadline cancels the entire dwell", !cancelledDwell.isHovering)
        check("proactive event does not wait for hover", cancelledDwell.presentation(hasLiveEvent: true, autoPop: true, hoverEnabled: true) == .medium)
        cancelledDwell.samplePointer(inside: true, at: 2.2)
        check("re-entry requires a new continuous 200 milliseconds", cancelledDwell.isHovering)

        var selected = IslandInteraction()
        selected.samplePointer(inside: true, at: 0)
        selected.samplePointer(inside: true, at: 0.1)
        selected.toggleExpanded(from: .medium)
        selected.samplePointer(inside: false, at: 1)
        selected.samplePointer(inside: false, at: 1.2)
        check("task selection is not a permanent pin", selected.presentation(hasLiveEvent: true, autoPop: true, hoverEnabled: false) == .medium)

        var spring = IslandSpring(32)
        spring.target = 448
        var maximum = spring.value
        for _ in 0..<120 { spring.advance(by: 1.0 / 120); maximum = max(maximum, spring.value) }
        check("spring has a small rebound", maximum > 448 && maximum < 457)
        check("spring settles", abs(spring.value - 448) < 0.1)

        var reduced = IslandSpring(448)
        reduced.target = 32
        reduced.advance(by: 1.0 / 120, reduceMotion: true)
        check("reduce motion snaps without rebound", reduced.value == 32 && reduced.velocity == 0)
        check("product has four user-facing agents", AgentCatalog.supportedKinds == [.codex, .claude, .doubao, .workBuddy])

        let metrics = IslandMetrics(notchWidth: 184, notchHeight: 32)
        check("status expands horizontally only", metrics.size(for: .medium).height == 32 && metrics.size(for: .medium).width > 184)
        let calibrated = IslandMetrics(notchWidth: 210, notchHeight: 25, safeTop: 32)
        check("calibration width and height are independent", calibrated.size(for: .collapsed).width == 210 && calibrated.size(for: .collapsed).height == 25)
        check("negative calibration still protects camera in detail", calibrated.size(for: .heavy).height == 448)

        var motion = IslandMotion()
        motion.configure(metrics, initial: true)
        motion.setTarget(.heavy)
        var previousOpacity = 0.0
        var monotone = true
        for _ in 0..<360 {
            motion.advance(by: 1.0 / 120)
            if motion.frame.heavyOpacity < previousOpacity { monotone = false }
            previousOpacity = motion.frame.heavyOpacity
        }
        check("content never re-flashes while spring crosses target", monotone && motion.frame.heavyOpacity == 1)
        let expandedFrame = motion.frame
        motion.setTarget(.collapsed)
        motion.advance(by: 1.0 / 120)
        check("exit starts content fade, corner morph and shell contraction together",
              motion.frame.height < expandedFrame.height && motion.frame.shoulder < expandedFrame.shoulder &&
              motion.frame.bottomRadius < expandedFrame.bottomRadius && motion.frame.heavyOpacity > 0 &&
              motion.frame.heavyOpacity < 1 && motion.frame.heavyScale < 1)
        let exitOpacity = motion.frame.heavyOpacity
        motion.setTarget(.heavy)
        motion.advance(by: 1.0 / 120)
        check("exit reversal does not zero visible content", motion.frame.heavyOpacity >= exitOpacity)
        for _ in 0..<120 { motion.advance(by: 1.0 / 120) }
        motion.setTarget(.collapsed)
        for _ in 0..<360 { motion.advance(by: 1.0 / 120) }
        check("idle leaves no painted extension below hardware", motion.frame.shellOpacity == 0 && motion.frame.width == 184 && motion.frame.height == 32)

        motion.setTarget(.medium)
        var constantHeight = true
        for _ in 0..<360 {
            motion.advance(by: 1.0 / 120)
            if abs(motion.frame.height - 32) > 0.001 { constantHeight = false }
        }
        check("medium spring never changes height", constantHeight && motion.frame.mediumOpacity == 1)
        for _ in 0..<10 {
            motion.setTarget(.heavy)
            for _ in 0..<15 { motion.advance(by: 1.0 / 120) }
            motion.setTarget(.collapsed)
            for _ in 0..<10 { motion.advance(by: 1.0 / 120) }
        }
        for _ in 0..<360 { motion.advance(by: 1.0 / 120) }
        check("ten rapid reversals settle fully home", motion.isSettled && motion.frame.shellOpacity == 0)
        motion.setTarget(.heavy)
        motion.advance(by: 1.0 / 120, reduceMotion: true)
        check("reduce motion detail is immediate", motion.frame.heavyOpacity == 1 && motion.frame.height == 448)
        motion.setTarget(.collapsed)
        motion.advance(by: 1.0 / 120, reduceMotion: true)
        check("reduce motion leaves only hardware", motion.frame.shellOpacity == 0 && motion.frame.height == 32)

        do {
            let providers: [AgentKind] = [.codex, .claude, .workBuddy]
            let session = "acceptance-shared-session"
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let lifecycle: [(name: String, type: String, status: AgentTaskStatus?)] = [
                ("SessionStart", "connection", nil),
                ("UserPromptSubmit", "upsert", .running),
                ("PermissionRequest", "upsert", .waiting),
                ("PreToolUse", "upsert", .running),
                ("PostToolUse", "upsert", .running),
                ("PostToolUseFailure", "upsert", .running),
                ("Stop", "upsert", .completed),
                ("StopFailure", "upsert", .failed),
                ("Interrupt", "upsert", .cancelled),
                ("SessionEnd", "end-session", .cancelled)
            ]
            let secret = "HOOK_PRIVACY_SENTINEL"
            let privateFields: [String: Any] = [
                "prompt": secret, "user_prompt": secret, "body": secret,
                "message": secret, "last_assistant_message": secret,
                "tool_name": secret, "tool_input": ["command": secret],
                "tool_output": secret, "tool_response": ["content": secret],
                "transcript_path": "/private/" + secret, "cwd": "/private/" + secret,
                "environment": ["TOKEN": secret], "progress": 0.87,
                "title": secret, "detail": secret, "model": secret
            ]
            let allowedKeys: Set<String> = [
                "type", "id", "agent", "title", "status", "detail", "model",
                "requiresApproval", "colorHex", "createdAt", "sourceEvent",
                "sessionID", "turnID", "legacySessionID", "replacesTaskID", "toolLabel", "toolStepID"
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var ids = Set<UUID>()

            func payload(_ name: String, sessionID: String? = nil,
                         extra: [String: Any] = [:]) throws -> Data {
                var value: [String: Any] = ["hook_event_name": name, "session_id": sessionID ?? session]
                value.merge(extra) { _, replacement in replacement }
                return try JSONSerialization.data(withJSONObject: value)
            }

            for provider in providers {
                var providerID: UUID?
                var metadataOnly = true
                var noProgress = true
                for expected in lifecycle {
                    let cleanPayload = try payload(expected.name)
                    let dirtyPayload = try payload(expected.name, extra: privateFields)
                    guard let clean = HookEventMapper.map(provider: provider, payload: cleanPayload, now: now),
                          let mapped = HookEventMapper.map(provider: provider, payload: dirtyPayload, now: now),
                          let id = mapped.id else {
                        check("\(provider.rawValue) maps \(expected.name)", false)
                        continue
                    }
                    if let previous = providerID {
                        check("\(provider.rawValue) \(expected.name) retains session identity", id == previous)
                    } else {
                        providerID = id
                        ids.insert(id)
                    }
                    check("\(provider.rawValue) \(expected.name) lifecycle mapping",
                          mapped.type == expected.type && mapped.status == expected.status &&
                          mapped.requiresApproval == (expected.status == .waiting) &&
                          mapped.agent == provider.displayName && mapped.sourceEvent == expected.name &&
                          mapped.createdAt == now)
                    let encoded = try encoder.encode(mapped)
                    let cleanEncoded = try encoder.encode(clean)
                    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                    metadataOnly = metadataOnly && encoded == cleanEncoded &&
                        !String(decoding: encoded, as: UTF8.self).contains(secret) &&
                        !String(decoding: encoded, as: UTF8.self).contains(session) &&
                        Set(object?.keys.map { $0 } ?? []).isSubset(of: allowedKeys)
                    noProgress = noProgress && mapped.progress == nil && object?["progress"] == nil
                }
                check("\(provider.rawValue) hooks retain only allowlisted metadata", metadataOnly)
                check("\(provider.rawValue) hooks never invent a percentage", noProgress)

                for notification in ["permission_prompt", "elicitation_dialog", "agent_needs_input"] {
                    let data = try payload("Notification", extra: ["notification_type": notification, "message": secret])
                    let event = HookEventMapper.map(provider: provider, payload: data, now: now)
                    check("\(provider.rawValue) \(notification) requests user attention",
                          event?.status == .waiting && event?.requiresApproval == true &&
                          event?.id == providerID && event?.progress == nil && event?.detail?.contains(secret) == false)
                }
                let unknown = try payload("FutureUnknownEvent")
                let irrelevant = try payload("Notification", extra: ["notification_type": "idle_prompt"])
                let nestedStop = try payload("Stop", extra: ["agent_id": "nested-agent"])
                let nestedTool = try payload("PreToolUse", extra: ["agent_id": "nested-agent"])
                check("\(provider.rawValue) unknown and unrelated notifications are ignored",
                      HookEventMapper.map(provider: provider, payload: unknown, now: now) == nil &&
                      HookEventMapper.map(provider: provider, payload: irrelevant, now: now) == nil)
                check("\(provider.rawValue) subagent events cannot change parent status",
                      HookEventMapper.map(provider: provider, payload: nestedStop, now: now) == nil &&
                      HookEventMapper.map(provider: provider, payload: nestedTool, now: now) == nil)
                let anotherSession = try payload("UserPromptSubmit", sessionID: "another-session")
                check("\(provider.rawValue) independent sessions have independent identities",
                      HookEventMapper.map(provider: provider, payload: anotherSession, now: now)?.id != providerID)
            }
            check("three providers sharing a session never share a task identity", ids.count == 3)
            let valid = try payload("UserPromptSubmit")
            check("Doubao and custom providers cannot fabricate hook task status",
                  HookEventMapper.map(provider: .doubao, payload: valid, now: now) == nil &&
                  HookEventMapper.map(provider: .custom, payload: valid, now: now) == nil)
            let emptySession = try payload("UserPromptSubmit", sessionID: "")
            let longSession = try payload("UserPromptSubmit", sessionID: String(repeating: "x", count: 257))
            let missingSession = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop"])
            check("malformed or missing session metadata is ignored",
                  HookEventMapper.map(provider: .codex, payload: Data("not-json".utf8), now: now) == nil &&
                  HookEventMapper.map(provider: .codex, payload: emptySession, now: now) == nil &&
                  HookEventMapper.map(provider: .codex, payload: longSession, now: now) == nil &&
                  HookEventMapper.map(provider: .codex, payload: missingSession, now: now) == nil)
        } catch {
            check("hook mapper test fixture serialization: \(error)", false)
        }

        runMotionRevisionChecks { name, condition in check(name, condition) }
        runHookRevisionChecks { name, condition in check(name, condition) }
        runButlerRevisionChecks { name, condition in check(name, condition) }
        runReleaseRevisionChecks { name, condition in check(name, condition) }
        runWingLayoutRevisionChecks { name, condition in check(name, condition) }
        runLabelMotionChecks { name, condition in check(name, condition) }

        print("\n\(checks) acceptance checks passed")
    }
}
