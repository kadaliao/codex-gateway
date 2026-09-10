# codex-gateway

**macOS 原生应用**：完整使用、构建与卸载说明见 [app/README.md](app/README.md)。

## 下载安装

从 [Releases](https://github.com/kadaliao/codex-gateway/releases) 下载最新的
`CodexGateway-<版本>-macos.zip`，解压后把 `Codex Gateway.app` 拖进「应用程序」。

构建是 ad-hoc 签名的，没有 Apple Developer ID 公证，所以 macOS 首次打开会拦。**右键点 App → 打开 → 再点「打开」**，
一次之后不再提示。若提示「已损坏，无法打开」：

```bash
xattr -dr com.apple.quarantine "/Applications/Codex Gateway.app"
```

需要 macOS 13 (Ventura) 或更高版本，Apple Silicon（M 系列）。在 Intel Mac 上请从源码构建，
构建前先安装 Homebrew 的 zstd。

让 Codex 在**一个模型选择器里跨 Provider 选模型**（OpenAI / DeepSeek / qwen / Ollama / LM Studio …）。
它读取本地 Codex 配置 `~/.codex/config.toml` 里的 `model_providers`，把它们聚合成一个 Codex 眼中的「Provider」，
并保留原模型目录和原连接能力。

```
codex ── /v1/models  ──▶  gateway ──  聚合 ~/.codex/config.toml 的 model_providers
      ── /v1/responses─▶  路由   ──  openai   : Responses 直通（保留全部功能）
                                  ├─ deepseek : 转 /v1/chat/completions 再翻译回 Codex
                                  └─ 其它     : 同上
```

## 为什么「不丢功能」

最关键的判断：凡是 OpenAI 系后端（`api.openai.com` / `chatgpt.com` / 原 Codex provider），
网关把它当作 Responses 后端做原样直通——`web_search`、`computer_use`、图片生成、reasoning items、流式，全部原封不动转发并流回。

只有 DeepSeek 这类只提供 `/v1/chat/completions` 的后端，才走 items↔messages 翻译（文本 + function/tool 调用）。
这类模型本来也不支持 computer_use / 图片生成，所以不是「丢了」，而是它自身没有这些能力。

发往**自定义服务**的历史在转发前还会做一次顺序规范化：把夹在函数调用与其输出之间的助手文本移到调用之前。
模型同时返回文本和工具调用时，Codex 会依次发出调用、文本、输出；部分第三方 Responses 网关按位置配对两者，
会误报 `No tool output found for tool call …`。原 Codex provider 的请求正文与顺序仍原样转发。

## macOS App

构建和使用步骤见 [app/README.md](app/README.md)。应用提供 Provider 编辑、模型选择、实时日志、停止恢复和卸载，
关闭主窗口后可从菜单栏重新打开；退出应用会先恢复 Codex。

内置 `ollama`、`lmstudio` 和 `amazon-bedrock` 暂不支持透明接入，连接前会被拒绝。标准 HTTP(S) 自定义 provider
和内置 OpenAI 受支持。

## 验证

```bash
swift test --package-path app
```

测试使用临时目录和本地模拟上游，覆盖原目录完整保留、名称冲突、配置恢复/并发编辑、旧配置迁移、卸载、
HTTP 状态和认证隔离、SSE 首包、WebSocket 原生事件、大请求与 chunked 解析，不会修改真实 Codex 配置或调用付费模型。

## 发布

推送 `v*` 形式的 tag 会触发 [release workflow](.github/workflows/release.yml)：
在 macOS runner 上跑测试、构建 `.app`、打包成 zip 并附上 SHA-256 校验文件，最后发布到 GitHub Releases。

```bash
git tag v0.2.2 && git push origin v0.2.2
```

也可以到 Actions 页面手动触发 `workflow_dispatch`，填一个已存在的 tag。
