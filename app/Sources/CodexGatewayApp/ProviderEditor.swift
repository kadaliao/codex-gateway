import SwiftUI

struct ProviderEditor: View {
    @ObservedObject var model: AppModel
    let existing: CustomProvider?
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var name = ""
    @State private var base = ""
    @State private var key = ""
    @State private var protocolName = "responses"
    @State private var showConnection = false
    @State private var automatic = false
    @State private var selected: Set<String> = []
    @State private var knownModels: Set<String> = []
    @State private var discoveredModels: Set<String> = []
    @State private var search = ""
    @State private var onlySelected = false
    @State private var manual = ""
    @State private var saving = false
    @State private var discovering = false
    @State private var error: String?
    @State private var discoveryTask: Task<Void, Never>?

    private var visibleModels: [String] {
        let terms = search.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let candidates = automatic ? discoveredModels : knownModels
        return candidates.filter { candidate in
            (!onlySelected || automatic || selected.contains(candidate)) &&
                terms.allSatisfy { candidate.localizedCaseInsensitiveContains($0) }
        }.sorted()
    }
    private var selectedCount: Int { automatic ? discoveredModels.count : selected.count }
    private var busy: Bool { saving || discovering }
    private var draft: CustomProvider {
        CustomProvider(id: id, name: name, baseURL: base, key: key, wireAPI: protocolName,
                       models: automatic ? [] : selected.sorted(), enabled: existing?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(existing == nil ? "添加 Provider" : "编辑 \(existing!.name)").font(.title2.weight(.semibold))
                    Text("搜索并勾选要在 Codex 中使用的模型。").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "server.rack").font(.title).foregroundStyle(.teal)
            }
            DisclosureGroup("连接设置", isExpanded: $showConnection) {
                Form {
                    TextField("Provider ID", text: $id)
                    TextField("显示名称", text: $name)
                    TextField("服务地址", text: $base, prompt: Text("https://api.example.com/v1"))
                    SecureField("API Key", text: $key, prompt: Text("密钥，或 env:ENV_VAR；本地服务可留空"))
                    Picker("接口协议", selection: $protocolName) {
                        Text("Responses").tag("responses")
                        Text("Chat Completions").tag("chat")
                    }
                }.textFieldStyle(.roundedBorder).padding(.top, 8).disabled(busy)
            }
            .font(.callout)
            .onChange(of: base) { _ in invalidateDiscovery() }
            .onChange(of: key) { _ in invalidateDiscovery() }
            Divider()
            Picker("要加入 Codex 的模型", selection: $automatic) {
                Text("挑选模型").tag(false)
                Text("自动加入全部").tag(true)
            }.pickerStyle(.segmented).disabled(busy)
            if automatic {
                Text("加入自动发现的全部模型，后续刷新也会加入新模型。切换到「挑选模型」可限定范围。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索模型，例如 deepseek v4", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("清除搜索")
                    }
                }.padding(9).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                if discovering { ProgressView().controlSize(.small) }
                Button { discoveryTask = Task { await discover() } } label: {
                    Label("获取模型", systemImage: "arrow.clockwise")
                }.disabled(busy || id.isEmpty || base.isEmpty)
            }
            HStack(spacing: 12) {
                Text("已选 \(selectedCount) 个").font(.callout.weight(.semibold)).foregroundStyle(.teal)
                Text("当前显示 \(visibleModels.count) 个").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("只看已选", isOn: $onlySelected).toggleStyle(.checkbox).fixedSize().disabled(automatic)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleModels, id: \.self) { modelID in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { automatic || selected.contains(modelID) },
                                set: { checked in
                                    if checked { selected.insert(modelID) } else { selected.remove(modelID) }
                                }
                            )) {
                                Text(modelID).font(.system(.body, design: .monospaced))
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.toggleStyle(.checkbox).disabled(automatic || busy)
                            if !discoveredModels.contains(modelID) {
                                Text("已保存 / 手动").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                            .background(selected.contains(modelID) && !automatic ? Color.teal.opacity(0.055) : .clear)
                        Divider().opacity(0.4)
                    }
                    if visibleModels.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: knownModels.isEmpty ? "square.stack.3d.up" : "magnifyingglass").font(.title2)
                            Text(emptyMessage).multilineTextAlignment(.center)
                        }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
            HStack {
                Button("选中当前结果") { selected.formUnion(visibleModels) }
                    .disabled(automatic || busy || visibleModels.isEmpty)
                Button("取消当前结果") { selected.subtract(visibleModels) }
                    .disabled(automatic || busy || !visibleModels.contains(where: { selected.contains($0) }))
                Spacer()
                if !automatic && selected.isEmpty {
                    Text("至少选择一个模型").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !automatic {
                DisclosureGroup("找不到模型？手动添加") {
                    HStack {
                        TextField("模型 ID，多个可用逗号分隔", text: $manual).textFieldStyle(.roundedBorder)
                        Button("添加") { addManualModels() }.disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }.padding(.top, 8)
                }.font(.caption).disabled(busy)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(automatic ? "保存 · 自动加入全部" : "保存 · \(selected.count) 个模型") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || model.isBusy || id.isEmpty || base.isEmpty || (!automatic && selected.isEmpty))
            }
        }
        .padding(24).frame(width: 680, height: 740)
        .interactiveDismissDisabled(saving)
        .task {
            showConnection = existing == nil
            if let existing {
                id = existing.id; name = existing.name; base = existing.baseURL; key = existing.key
                protocolName = existing.wireAPI ?? "chat"
                selected = Set(existing.models ?? [])
                automatic = selected.isEmpty
                knownModels = selected
                // onChange of the initial connection values runs after this task.
                // Discover once using the draft, without changing saved settings.
                await discover()
            }
        }
        .onDisappear { discoveryTask?.cancel() }
    }

    private var emptyMessage: String {
        if discovering { return "正在获取模型…" }
        if onlySelected { return "还没有选中的模型，关闭「只看已选」开始挑选。" }
        if !search.isEmpty { return "没有匹配的模型，试试缩短搜索词。" }
        return "填写连接设置，然后点击「获取模型」。\n服务不提供模型列表时，也可以手动添加。"
    }
    private func invalidateDiscovery() {
        discoveredModels = []
        knownModels = selected
    }
    private func discover() async {
        guard !discovering else { return }
        discovering = true; error = nil
        defer { discovering = false }
        do {
            let provider = try AppModel.validated(draft)
            let models = try await ModelCatalog.listProviderModels(provider.toProviderConfig())
            guard !Task.isCancelled else { return }
            discoveredModels = Set(models)
            knownModels = discoveredModels.union(selected)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = safeError(error)
        }
    }
    private func addManualModels() {
        let added = manual.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        knownModels.formUnion(added); selected.formUnion(added)
        manual = ""; search = ""; onlySelected = true
    }
    private func save() {
        saving = true; error = nil
        Task {
            if await model.saveProvider(draft, replacing: existing?.id) { dismiss() }
            else { error = model.onError }
            saving = false
        }
    }
}
