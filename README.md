# Codex Gateway

让 Codex 在**一个模型选择器里跨 Provider 选模型**（OpenAI / DeepSeek / 自建服务 …），并在切换时保住 Codex 原本的能力。

原生 macOS 应用：Provider 管理、模型挑选、实时日志、停止恢复、卸载都在界面里完成，关掉主窗口后从菜单栏打开。
应用细节见 [app/README.md](app/README.md)。

## 功能

- **聚合模型列表** — 读取 `~/.codex/config.toml` 的 `model_providers`，把各服务的模型追加进 Codex 的模型目录。原模型对象和目录元数据逐字段保留，不重新发现、不重建原 provider 的模型。
- **不丢功能** — OpenAI 系后端（`api.openai.com` / `chatgpt.com` / 原 Codex provider）按 Responses 原样直通：`web_search`、`computer_use`、图片生成、reasoning items、流式响应全部原封不动转发并流回。
- **只转必要的一层** — 仅提供 `/v1/chat/completions` 的服务（如 DeepSeek）在网关里做 items ↔ messages 翻译，覆盖文本和 function/tool 调用。这类服务本身没有的能力不会被伪造。支持原生 Responses 的服务走直通。
- **挑选而不是全塞** — Provider 编辑页「获取模型」支持多关键词搜索、只看已选、选中/取消当前结果；默认只加入选中的模型，也可显式切到「自动加入全部」。服务不提供模型列表时可手动添加。
- **可逆接入** — 连接期间只临时改当前 provider 的 `base_url`（内置 OpenAI 用 `openai_base_url`）和顶层 `model_catalog_json`，恢复日志在改动之前原子写入。「停止并恢复」或退出应用即撤回；卸载连服务、密钥、日志一起清理。
- **本机运行** — 只监听 `127.0.0.1`，没有登录启动项、LaunchAgent、系统代理或证书安装；日志不记录对话正文、响应正文和密钥。

## 下载安装

从 [Releases](https://github.com/kadaliao/codex-gateway/releases) 下载 `CodexGateway-<版本>-macos.zip`，解压后把 `Codex Gateway.app` 拖进「应用程序」。

构建是 ad-hoc 签名的，没有 Apple Developer ID 公证，macOS 首次打开会拦：**右键点 App → 打开 → 再点「打开」**，一次之后不再提示。若提示「已损坏，无法打开」：

```bash
xattr -dr com.apple.quarantine "/Applications/Codex Gateway.app"
```

要求 macOS 13 (Ventura) 或更高、Apple Silicon（M 系列）。Intel Mac 请从源码构建，构建前先装 Homebrew 的 `zstd`。

## 怎么工作

```
codex ── /v1/models    ──▶ gateway ──  聚合 ~/.codex/config.toml 的 model_providers
      ── /v1/responses ──▶   路由   ──  openai / chatgpt / 原 provider : Responses 直通
                                      ├─ deepseek 等                 : 转 /v1/chat/completions 再翻译回来
                                      └─ 支持 Responses 的自定义服务  : 直通
```

连接后 Codex 看到的仍是一个 provider（默认保留原 provider ID），模型选择器里同时出现原模型和自定义服务的模型。名称冲突时自定义模型用 `provider/model`，不冲突时保留原名。

## 从源码构建

需要 macOS 13+、Swift 5.9+、Homebrew 的 `zstd`（构建脚本把动态库打进应用包）。

```bash
brew install zstd
cd app
./build-app.sh
open "build/Codex Gateway.app"
```

验证：

```bash
swift test --package-path app
```

测试用临时目录和本地模拟上游，覆盖原目录保留、名称冲突、配置恢复/并发编辑、旧配置迁移、卸载、HTTP 状态与认证隔离、SSE 首包、WebSocket 原生事件、大请求与 chunked 解析、工具调用顺序规范化；不改真实 Codex 配置，也不调用付费模型。`CODEX_HOME`、`CODEX_GATEWAY_HOME` 可指定隔离目录。

## 已知限制

- 内置 `ollama`、`lmstudio`、`amazon-bedrock` 暂不支持透明接入，连接前会被拒绝；标准 HTTP(S) 自定义 provider 和内置 OpenAI 受支持。
- Codex 的模型目录在启动时加载。首次接入、新增模型或停止接入后，已经在跑的 Codex 需要重新加载配置；应用不会强制重启 Codex。
- 其他配置 profile 若覆盖 provider 或目录，需要单独评估——本应用只接入用户级当前配置。

## 发布

推送 `v*` tag 触发 [release workflow](.github/workflows/release.yml)：跑测试、构建 `.app`、打包 zip + SHA-256，发布到 GitHub Releases。也可在 Actions 页面手动 `workflow_dispatch`，填一个已存在的 tag。

```bash
git tag v0.2.3 && git push origin v0.2.3
```
