import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var skipCleanup = false
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { !skipCleanup }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !skipCleanup, let model else { return .terminateNow }
        Task {
            while model.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            sender.reply(toApplicationShouldTerminate: await model.stop())
        }
        return .terminateLater
    }
}

@main
struct CodexGatewayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Codex Gateway", id: "main") {
            GatewayWindow(model: model, delegate: delegate)
                .onAppear { delegate.model = model }
                .task { await model.refresh() }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        MenuBarExtra("Codex Gateway", systemImage: model.isRunning ? "network" : "network.slash") {
            GatewayMenu(model: model)
        }
    }
}

struct GatewayMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        Button("打开控制台") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(model.isRunning ? "停止并恢复 Codex" : "连接 Codex") {
            Task { if model.isRunning { await model.stop() } else { await model.connect() } }
        }.disabled(model.isBusy)
        Divider()
        Button("退出 Codex Gateway") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct GatewayWindow: View {
    @ObservedObject var model: AppModel
    let delegate: AppDelegate
    @State private var editing: CustomProvider?
    @State private var adding = false
    @State private var deleting: CustomProvider?
    @State private var confirmUninstall = false
    @State private var search = ""
    @State private var logFilter = "all"
    private let pages = [("overview", "总览", "square.grid.2x2"), ("providers", "Providers", "server.rack"),
                         ("models", "模型列表", "square.stack.3d.up"), ("logs", "实时日志", "text.alignleft"),
                         ("settings", "设置与卸载", "gearshape")]

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 27, weight: .medium)).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Codex Gateway").font(.headline)
                        Text("一个列表，多个模型服务").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 14)
                VStack(spacing: 5) {
                    ForEach(pages, id: \.0) { page in
                        Button { model.selectedPage = page.0; search = "" } label: {
                            HStack {
                                Label(page.1, systemImage: page.2)
                                Spacer()
                                if page.0 == "providers" { Text("\(model.customProviders.count)").font(.caption.monospacedDigit()) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(model.selectedPage == page.0 ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(model.selectedPage == page.0 ? Color.accentColor : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isRunning ? .green : .gray).frame(width: 7, height: 7)
                    Text(model.status).font(.caption)
                }
                Text(model.gatewayBase).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(18)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 270)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.onError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button { model.onError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.font(.callout).foregroundStyle(.red).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.08))
                }
                Group {
                    switch model.selectedPage {
                    case "providers": providersPage
                    case "models": modelsPage
                    case "logs": logsPage
                    case "settings": settingsPage
                    default: overviewPage
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 940, minHeight: 660)
        .toolbar {
            ToolbarItemGroup {
                if model.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy).help("重新读取配置并发现自定义模型")
                Button {
                    Task { if model.isRunning { await model.stop() } else { await model.connect() } }
                } label: {
                    Label(model.isRunning ? "停止并恢复" : "连接 Codex", systemImage: model.isRunning ? "stop.circle" : "bolt.fill")
                }.buttonStyle(.borderedProminent).tint(model.isRunning ? .orange : .accentColor).disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $adding) { ProviderEditor(model: model, existing: nil) }
        .sheet(item: $editing) { provider in ProviderEditor(model: model, existing: provider) }
        .confirmationDialog("移除 \(deleting?.name ?? "")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("移除 provider", role: .destructive) { if let provider = deleting { model.removeProvider(provider.id) }; deleting = nil }
        } message: { Text("会移除该服务及其自定义模型，原 Codex 模型不受影响。") }
        .confirmationDialog("卸载 Codex Gateway？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("恢复 Codex 并卸载", role: .destructive) {
                Task { if await model.uninstall(removeApp: true) { delegate.skipCleanup = true; NSApp.terminate(nil) } }
            }
        } message: { Text("先恢复原连接并停止服务，再删除自定义 provider、保存的密钥、日志与应用偏好，将应用移到废纸篓。Codex 原模型、登录信息和任务保留。") }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 24)
    }
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
    private func metric(_ title: String, value: String, footnote: String, icon: String) -> some View {
        card(title, icon: icon) {
            Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading("所有模型，就在一起。", "保留熟悉的 Codex 工作方式，在同一个模型列表里使用自定义服务。")
                HStack(spacing: 14) {
                    metric("原有模型", value: "\(model.snapshot?.originalCount ?? 0)", footnote: "名称与能力配置完整保留", icon: "checkmark.shield")
                    metric("自定义模型", value: "\(model.snapshot?.routes.count ?? 0)", footnote: "仅重名时增加 provider 前缀", icon: "square.stack.3d.up")
                    metric("自定义服务", value: "\(model.enabledCount)", footnote: "已启用 / 共 \(model.customProviders.count) 个", icon: "server.rack")
                }
                card("Codex 连接", icon: "point.3.connected.trianglepath.dotted") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.isRunning ? "已接入，原模型继续走原服务" : "准备就绪后，一键连接").font(.title3.weight(.medium))
                            Text("当前 provider：\(model.activeProvider)  ·  默认模型：\(model.activeModel)")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("接入仅临时修改连接地址和模型目录引用。停止或退出时自动恢复。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: model.isRunning ? "checkmark.circle.fill" : "link.circle")
                            .font(.system(size: 42)).foregroundStyle(model.isRunning ? .green : .teal)
                    }
                    Divider()
                    Label("首次接入及停止后，已打开的 Codex 可能需要重新加载配置。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 14) {
                    card("自定义服务", icon: "server.rack") {
                        if model.customProviders.isEmpty {
                            Text("添加第一个 provider，或填写手动模型 ID。").foregroundStyle(.secondary)
                        }
                        ForEach(model.customProviders.prefix(3)) { provider in
                            HStack {
                                Circle().fill(provider.enabled == false ? .gray : .teal).frame(width: 6, height: 6)
                                Text(provider.name)
                                Spacer()
                                Text("\(model.snapshot?.routes.values.filter { $0.providerID == provider.id }.count ?? 0) 个模型").foregroundStyle(.secondary)
                            }
                        }
                        Button("管理 Providers") { model.selectedPage = "providers" }
                    }
                    card("最近活动", icon: "waveform.path") {
                        ForEach(model.logs.suffix(3)) { entry in
                            Text(entry.line).font(.caption).foregroundStyle(entry.level == "error" ? .red : .secondary).lineLimit(2)
                        }
                        Button("查看实时日志") { model.selectedPage = "logs" }
                    }
                }
            }.padding(28)
        }
    }

    private var providersPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    heading("Providers", "自定义服务独立保存；原 Codex provider 只读展示。")
                    Spacer()
                    Button { adding = true } label: { Label("添加 Provider", systemImage: "plus") }.disabled(model.isBusy)
                }
                ForEach(model.customProviders) { provider in
                    card(provider.name, icon: "server.rack") {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(provider.id + "  ·  " + (provider.wireAPI == "responses" ? "Responses" : "Chat Completions"))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(provider.baseURL).font(.callout).textSelection(.enabled)
                                HStack {
                                    Label(discoveryText(provider), systemImage: discoveryIcon(provider))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !(provider.models ?? []).isEmpty { Text("手动 \(provider.models!.count) 个").font(.caption).foregroundStyle(.teal) }
                                }
                            }
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { provider.enabled != false }, set: { _ in model.toggleProvider(provider.id) }))
                                .toggleStyle(.switch).fixedSize().disabled(model.isBusy)
                            Button("编辑") { editing = provider }.disabled(model.isBusy)
                            Button { deleting = provider } label: { Image(systemName: "trash") }.disabled(model.isBusy).help("移除 provider")
                        }
                    }
                }
                if model.customProviders.isEmpty {
                    card("还没有自定义 Provider", icon: "plus.circle") {
                        Text("填写服务地址、密钥和协议，保存后自动发现模型。服务不提供 /models 时可手动添加。")
                            .foregroundStyle(.secondary)
                        Button("添加 Provider") { adding = true }
                    }
                }
                Text("原 Codex 配置").font(.headline).padding(.top, 10)
                ForEach(model.codexProviders.keys.sorted(), id: \.self) { id in
                    if let provider = model.codexProviders[id] {
                        card(provider.name, icon: "lock.shield") {
                            HStack {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(id + (id == model.activeProvider ? "  ·  当前使用" : "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(provider.baseURL ?? "内置服务").textSelection(.enabled)
                                }
                                Spacer()
                                Text("只读").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.padding(28)
        }
    }
    private func discoveryText(_ provider: CustomProvider) -> String {
        if provider.enabled == false { return "已停用" }
        return model.discoveryStatus[provider.id] ?? "等待发现模型"
    }
    private func discoveryIcon(_ provider: CustomProvider) -> String {
        model.discovered[provider.id] != nil ? "checkmark.circle" : "info.circle"
    }

    private var filteredModels: [[String: Any]] {
        (model.snapshot?.models ?? []).filter { item in
            let id = item["slug"] as? String ?? ""
            return search.isEmpty || id.localizedCaseInsensitiveContains(search) || (model.snapshot?.routes[id]?.providerID ?? model.activeProvider).localizedCaseInsensitiveContains(search)
        }
    }
    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("模型列表", "原模型优先保留原名。此处显示将写入 Codex 模型目录的实际 ID。")
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索模型或 provider", text: $search).textFieldStyle(.plain)
                Text("\(filteredModels.count) 个").foregroundStyle(.secondary)
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 16)
            HStack { Text("模型 ID").frame(maxWidth: .infinity, alignment: .leading); Text("服务 / 来源").frame(width: 180, alignment: .leading) }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredModels.indices, id: \.self) { index in
                        let item = filteredModels[index]
                        let id = item["slug"] as? String ?? ""
                        let route = model.snapshot?.routes[id]
                        HStack(spacing: 12) {
                            Image(systemName: route == nil ? "lock.shield" : "sparkle").foregroundStyle(route == nil ? Color.secondary : .teal)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(id).font(.body.monospaced()).textSelection(.enabled)
                                if let route, route.modelID != id { Text("上游 ID：\(route.modelID)").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route?.providerID ?? model.activeProvider)
                                Text(route == nil ? "原有配置 · 保留" : "自定义 · 追加").font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 180, alignment: .leading)
                        }.padding(12).background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                    }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }.padding(28)
    }

    private var logsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("实时日志", "查看连接、模型发现与请求结果。日志不记录密钥、请求正文或回复内容。")
            HStack {
                Picker("级别", selection: $logFilter) { Text("全部").tag("all"); Text("请求").tag("request"); Text("错误").tag("error") }.frame(width: 200)
                TextField("搜索日志", text: $search).textFieldStyle(.roundedBorder)
                Button("导出") { exportLogs() }
                Button("清空") { model.clearLogs() }
            }.padding(.bottom, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.logs.filter { (logFilter == "all" || $0.level == logFilter) && (search.isEmpty || $0.line.localizedCaseInsensitiveContains(search)) }) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                                Text(entry.level.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).frame(width: 64, alignment: .leading)
                                    .foregroundStyle(entry.level == "error" ? .red : .teal)
                                Text(entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 9).padding(.horizontal, 12).id(entry.id)
                            Divider().opacity(0.5)
                        }
                        if model.logs.isEmpty { Text("暂无日志").foregroundStyle(.secondary).padding(24) }
                    }
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: model.logs.count) { _ in if let last = model.logs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Text("保留最近 500 条显示记录，磁盘日志自动轮转。关闭窗口后服务继续运行；退出应用会恢复 Codex。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
        }.padding(28)
    }
    private func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "codex-gateway.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.logs.map(\.line).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { model.fail(error) }
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading("设置与卸载", "连接可撤回，数据有明确归属。")
                card("配置与存储", icon: "folder") {
                    LabeledContent("Codex 配置") { Text(model.writer.configURL.path).font(.caption.monospaced()).textSelection(.enabled) }
                    LabeledContent("Gateway 数据") { Text(model.dataDirectory.path).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("自定义密钥保存在仅当前用户可读的文件中。原 provider 的登录和密钥继续由 Codex 管理。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("在 Finder 显示数据") { NSWorkspace.shared.activateFileViewerSelecting([model.dataDirectory]) }
                }
                card("停止与恢复", icon: "arrow.uturn.backward.circle") {
                    Text("停止会先恢复原连接和目录引用，再关闭本地监听与请求。只撤回 Gateway 自己的改动，保留其他配置更新。")
                        .foregroundStyle(.secondary)
                    Text("异常退出后，下次打开 Gateway 会尝试恢复。强制结束或电脑断电不能执行退出清理；可重新打开本应用恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("停止服务并恢复 Codex") { Task { await model.stop() } }.disabled(model.isBusy)
                }
                card("卸载应用", icon: "trash") {
                    Text("恢复 Codex，删除自定义服务、密钥、日志、Gateway 生成的目录与偏好，将本应用移到废纸篓。")
                        .foregroundStyle(.secondary)
                    Button("卸载 Codex Gateway…", role: .destructive) { confirmUninstall = true }.disabled(model.isBusy)
                }
            }.padding(28)
        }
    }
}
