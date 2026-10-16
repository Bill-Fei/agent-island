import LinglongtaiShared
import SwiftUI

/// Compact one-step review: who asks, what will run, then decide. The full
/// parameters stay one click away, so the card never hides what is approved.
struct ApprovalReviewView: View {
    let request: ApprovalRelay.Request
    @ObservedObject var store: TaskStore
    @ObservedObject private var conversationTitles = ConversationTitleStore.shared
    private var expanded: Bool { store.approvalReviewExpanded }

    private var isPending: Bool {
        store.tasks.first(where: { $0.id == request.taskID }).flatMap { store.approvalRequest(for: $0) } == request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentIcon(kind: request.provider, size: 20)
                Text(headline).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button { store.closeApproval() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Esc · 不做决定")
            }
            Text(request.tool).font(.system(size: 12)).foregroundStyle(.secondary)
            if !riskLabels.isEmpty {
                Label("含高风险操作：\(riskLabels.joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
            }
            commandBox
            if isPending {
                HStack(spacing: 8) {
                    Spacer()
                    Button { store.respondToApproval(request, decision: .deny) } label: { keyLabel("拒绝", "⌘⌫") }
                        .controlSize(.large)
                    Button { store.respondToApproval(request, decision: .allow) } label: { keyLabel("允许", "⌘↩") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .tint(riskLabels.isEmpty ? .accentColor : .red)
                        .help("只允许这一次，不授予长期权限")
                }
            } else {
                Text("请求已过期或已处理，请回原应用核实。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var headline: String {
        let title = store.tasks.first(where: { $0.id == request.taskID }).map { conversationTitles.title(for: $0) }
        return [request.provider.displayName, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var fields: [ApprovalShortcut.Field]? { ApprovalShortcut.fields(fromContext: request.context) }

    /// What the card is really about: the longest argument (usually the command).
    private var primary: ApprovalShortcut.Field? {
        fields?.filter { $0.key != "working_directory" }.max { $0.value.count < $1.value.count }
    }

    private var directory: String? {
        fields?.first(where: { $0.key == "working_directory" }).map { ($0.value as NSString).abbreviatingWithTildeInPath }
    }

    /// Other short arguments are shown only in the expanded view.
    private var hasMore: Bool {
        guard let fields, let primary else { return true }
        return fields.count > 2 || fields.contains { $0.key != "working_directory" && $0.key != primary.key }
            || primary.value.split(separator: "\n", omittingEmptySubsequences: false).count > 3 || primary.value.count > 140
    }

    private var riskLabels: [String] {
        if let fields { return ApprovalRisk.labels(in: fields) }
        return ApprovalRisk.matches(in: request.context).map(\.label).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                ScrollView { allParameters }.frame(maxHeight: 220)
            } else if let primary {
                Text(highlighted(primary.value))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(3).truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(highlighted(request.context)).font(.system(size: 12, design: .monospaced))
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if let directory, !expanded {
                    Text(directory).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if hasMore {
                    Button(expanded ? "收起" : "展开全文") { store.approvalReviewExpanded.toggle() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var allParameters: some View {
        if let fields {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.key).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(field.key == "working_directory" ? AttributedString(field.value) : highlighted(field.value))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(highlighted(request.context)).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in ApprovalRisk.matches(in: text) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = .red
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    private func keyLabel(_ title: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text(key).font(.system(size: 10, design: .rounded)).opacity(0.6)
        }
    }
}
