import LinglongtaiShared

extension TaskStore {
    /// Row click: select, and open the approval card when the row has a live approval.
    /// The card still shows the full params before any decision can be made.
    func selectOrReview(_ task: AgentTask) {
        select(task)
        if approvalRequest(for: task) != nil { reviewApproval(for: task) }
    }

    /// Keyboard entry into review (global hotkey). Never decides anything.
    func reviewPendingApproval() {
        guard let task = approvalTask else { return }
        select(task)
        reviewApproval(for: task)
    }

    /// Applies a shortcut to the request currently under review; ignored when nothing is reviewed.
    func handleApprovalShortcut(_ action: ApprovalShortcut.Action) {
        // A minimized card is unseen: only Esc may act on it.
        guard let request = reviewingApproval, !approvalMinimized || action == .close else { return }
        switch action {
        case .allowOnce:
            // Risky requests are allowed only by a deliberate press-and-hold.
            guard !approvalNeedsHold(request) else { return }
            respondToApproval(request, decision: .allow)
        case .deny: respondToApproval(request, decision: .deny)
        case .close: closeApproval()
        }
    }
}
