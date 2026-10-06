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
                Text("\(request.provider.displayName) 请求批准").font(.headline)
                Spacer()
                Button("关闭") { store.closeApproval() }
            }
            Text(request.tool).font(.subheadline)
            Text("本次请求的完整参数 · 仅在本机临时展示").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(request.context).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 170)
            Text(isPending ? "只批准这一次，不授予长期权限。请核对完整参数。" : "请求已过期或已处理，请回原应用核实。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("拒绝本次") { store.respondToApproval(request, decision: .deny) }
                    .disabled(!isPending)
                Spacer()
                Button("仅允许这一次") { store.respondToApproval(request, decision: .allow) }
                    .buttonStyle(.borderedProminent).disabled(!isPending)
            }
        }.padding(20).frame(width: 470)
    }
}
