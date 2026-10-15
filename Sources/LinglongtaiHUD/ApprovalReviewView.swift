import LinglongtaiShared
import SwiftUI

struct ApprovalReviewView: View {
    let request: ApprovalRelay.Request
    @ObservedObject var store: TaskStore

    private var isPending: Bool {
        store.tasks.first(where: { $0.id == request.taskID }).flatMap { store.approvalRequest(for: $0) } == request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AgentIcon(kind: request.provider, size: 28)
                Text("\(L(request.provider.displayName)) 请求批准").font(.headline)
                Spacer()
                Button("关闭") { store.closeApproval() }
                    .help("Esc · 不做决定")
            }
            Text(request.tool).font(.subheadline)
            if let origin { Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
            if !riskLabels.isEmpty { riskBanner }
            Text("本次请求的完整参数 · 仅在本机临时展示").font(.caption).foregroundStyle(.secondary)
            ScrollView { parameters }.frame(height: 170)
            Text(L(isPending ? "只批准这一次，不授予长期权限。请核对完整参数。" : "请求已过期或已处理，请回原应用核实。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { store.respondToApproval(request, decision: .deny) } label: { keyLabel("拒绝本次", "⌘⌫") }
                    .disabled(!isPending)
                Spacer()
                Button { store.respondToApproval(request, decision: .allow) } label: { keyLabel("仅允许这一次", "⌘↩") }
                    .buttonStyle(.borderedProminent).disabled(!isPending)
            }
        }.padding(20).frame(width: 470)
    }

    private var fields: [ApprovalShortcut.Field]? { ApprovalShortcut.fields(fromContext: request.context) }

    private var riskLabels: [String] {
        if let fields { return ApprovalRisk.labels(in: fields) }
        return ApprovalRisk.matches(in: request.context).map(\.label).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var origin: String? {
        let title = store.tasks.first(where: { $0.id == request.taskID })?.title
        let directory = fields?.first(where: { $0.key == "working_directory" })?.value
        let parts = [title, directory.map { ($0 as NSString).abbreviatingWithTildeInPath }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : L("来自：") + parts.joined(separator: " · ")
    }

    private var riskBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("含高风险操作：\(riskLabels.map(L).joined(separator: L("、")))。请逐字核对下方标红部分。")
        }
        .font(.caption).foregroundStyle(.red)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
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

    @ViewBuilder private var parameters: some View {
        if let fields {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.key).font(.caption).foregroundStyle(.secondary)
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

    private func keyLabel(_ title: String, _ key: String) -> some View {
        HStack(spacing: 6) {
            Text(L(title))
            Text(key).font(.system(size: 11, design: .rounded)).opacity(0.6)
        }
    }
}
