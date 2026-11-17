import SwiftUI
import MuxiCore

struct SiteSelector: View {
    let store: ViewingSiteStore
    let selectedName: String?
    let open: (ViewingSite) -> Void
    let manage: () -> Void
    @ViewState private var expanded = false
    @ViewState private var builtin = true

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedName ?? "选择观影站点").font(.callout.weight(.medium)).lineLimit(1)
                    Text("内置影视 · 自定义站点").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: 160, alignment: .leading)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5) }
        }.buttonStyle(.plain).fixedSize()
            .accessibilityLabel("选择观影站点").help("选择内置影视或自定义站点")
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                VStack(spacing: 14) {
                    Picker("站点分组", selection: $builtin) {
                        Text("内置影视").tag(true)
                        Text("自定义站点").tag(false)
                    }.pickerStyle(.segmented)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            let sites = store.allSites.filter { $0.enabled && $0.kind != .reference && $0.isDefault == builtin }
                            if sites.isEmpty { Text("暂无站点").foregroundStyle(.secondary).padding(12) }
                            ForEach(sites) { site in
                                Button { expanded = false; open(site) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(site.name).font(.callout.weight(.medium))
                                            Text(site.kind.label).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 350)
                    Divider()
                    Button("管理站点与测速") { expanded = false; manage() }
                }.padding(16).frame(width: 300)
            }
    }
}
