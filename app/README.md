# Codex Gateway for macOS

原生 macOS 控制台，将自定义模型追加到 Codex 的模型列表。包含总览、Provider 管理、模型列表、实时日志、停止恢复和卸载界面。关闭主窗口后可从菜单栏重新打开；退出应用会先恢复 Codex。

## 构建与使用

需要 macOS 13+、Swift 5.9+、Homebrew 的 `zstd`（仅构建时；构建脚本把动态库包含在应用包内）。

```bash
brew install zstd
cd app
./build-app.sh
open "build/Codex Gateway.app"
```

1. 打开 **Providers**。旧版本保存的自定义服务会自动迁移并显示。
2. 在 Provider 编辑页点击 **获取模型**，用搜索框和复选框挑选模型。支持多个搜索词、**只看已选**、**选中当前结果**和**取消当前结果**；原有选择会自动勾上。默认只加入已选模型，也可显式切换为 **自动加入全部**。服务不提供模型列表时，可展开手动添加入口。
3. 在 **模型列表** 中检查原模型和新增模型。点击 **连接 Codex**，监听成功后才应用接入设置。
4. 重新加载 Codex 配置后，在原来的模型选择器中选择模型。

`Responses` 用于支持原生 Responses 的服务。`Chat Completions` 用于只提供该接口的服务，当前覆盖文本和函数工具调用转换，等待完整回复后返回。它不能提供服务本身不支持的 Codex 功能。原 Codex provider 始终使用原生 Responses 路径。

## 原配置如何保留

- 原模型目录文件从不改写。生成的新目录逐字段保留所有原模型对象和目录元数据，再追加**启用的自定义服务**的模型。不会重新发现或重建原 provider 的模型。
- 原模型名称优先；自定义名称不冲突时保留原名，冲突时使用 `provider/model`。包含 `/` 的上游模型 ID 按完整字符串匹配。
- `model_provider`、默认 `model`、推理等级、模型能力和其他 provider 配置保持不变。
- 连接期间只临时改当前 provider 的 `base_url`（内置 OpenAI 使用 `openai_base_url`）和顶层 `model_catalog_json`。恢复日志保存在 `CODEX_HOME/.codex-gateway/connection.json`，在修改前原子写入。
- 停止恢复只撤回 Gateway 拥有的字段；运行期间的其他配置编辑会保留。恢复失败时保留网关和恢复日志，显示错误。
- 原服务保留 Codex 提供的认证、请求正文、请求元数据、流式响应与 WebSocket 消息。自定义服务仅使用自己的认证，不继承原服务凭据。
- 发往**自定义服务**的历史会做一次顺序规范化：把夹在函数调用与其输出之间的助手文本移到调用之前。模型同时返回文本和工具调用时，Codex 会依次发出调用、文本、输出；部分第三方 Responses 网关按位置配对两者，会误报 `No tool output found for tool call …`。原 Codex provider 的请求正文与顺序仍原样转发。
- 监听仅绑定 `127.0.0.1`。没有登录启动项、LaunchAgent、系统代理或证书安装。

**Codex 的目录在启动时加载。** 首次接入、新增模型或停止接入后，已经运行的 Codex 可能需要重新加载配置。不能承诺现有 Codex 进程即时更新模型或连接；应用不会强制重启 Codex。其他配置 profile 若覆盖 provider/目录，需要单独评估，本应用只接入用户级当前配置。保留原 provider ID 能避免由 Gateway 切换 provider 导致的任务过滤变化。

内置 `ollama`、`lmstudio` 和 `amazon-bedrock` 暂不支持透明接入，会在修改前拒绝连接。标准 HTTP(S) 自定义 provider 和内置 OpenAI 受支持。

## 日志、停止与卸载

- **实时日志**显示模型发现、请求路由、状态码和耗时；不记录对话正文、响应正文或密钥。支持筛选、搜索、导出和清空。
- 主窗口显示最近 500 条；磁盘日志达到 2 MB 自动轮转，保留一份旧日志。
- **停止并恢复**先恢复 Codex 原连接与模型目录引用，再取消请求、关闭端口、删除临时目录和恢复日志。
- **退出**执行同样清理。强制结束或断电无法运行退出代码；下次启动会读取恢复日志并尝试恢复。
- **设置与卸载 → 卸载 Codex Gateway**恢复 Codex，删除 Gateway 自定义服务、密钥、日志、偏好和生成文件，并把当前应用包移到废纸篓。恢复失败则中止卸载。用户自行导出的文件和源码仓库不删除。

应用数据位于 `~/Library/Application Support/Codex Gateway`，目录权限 `0700`，密钥文件 `0600`。密钥可以填写 `env:VARIABLE`；从 Finder 启动的应用只能读取其实际继承的环境变量。旧版 UserDefaults 配置在成功迁移后移除。不要在地址里放密钥。

## 验证

```bash
swift test --package-path app
```

测试使用临时目录和本地模拟上游：原目录完整保留、名称冲突、配置恢复/并发编辑、旧配置迁移、卸载、HTTP 状态和认证隔离、SSE 首包、WebSocket 原生事件、大请求与 chunked 解析、自定义服务的工具调用顺序规范化。不会修改真实 Codex 配置或调用付费模型。

`CODEX_HOME` 可指定隔离的 Codex 配置目录；`CODEX_GATEWAY_HOME` 可指定隔离的 Gateway 数据目录。构建应用采用 ad-hoc 签名，没有 Developer ID 或公证。

