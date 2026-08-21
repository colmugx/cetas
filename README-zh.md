# Cetas

**Cetas** 是一个构建在 [Posoco](https://github.com/colmugx/posoco) 之上的编程智能体。

### 目录结构

| 目录 | 说明 |
|---|---|
| [`cetas-core/`](./cetas-core/) | 库。所有宿主共享的目标无关宿主逻辑：`Cetas` 扩展（身份、系统提示词组装、`/profile` 命令）、provider 组装 / 凭据 / 登录、模型目录缓存、prompt 执行器。不做任何目标相关 IO——IO 全部由宿主注入。 |
| [`cetas-js/`](./cetas-js/) | **终端 UI 宿主。** 运行在 **Bun** 运行时上（js 目标），通过 Node 兼容的 `node:fs` / `node:crypto` FFI 做文件与加密 IO，用 **pi-tui** 渲染。 |
| [`cetas-acp/`](./cetas-acp/) | **编辑器宿主。** native 可执行文件，通过 stdio 把一个 Cetas Agent 暴露为 **ACP v1** agent，供 **Zed** 等 ACP 客户端驱动。 |

两个宿主都复用 `cetas-core`；它们自身都不包含 agent 循环逻辑——那属于它们组合出来的 Posoco `Agent`。

### 前置要求

- [MoonBit 工具链](https://docs.moonbitlang.com)（`moon`）。
- [Bun](https://bun.sh) —— 仅 `cetas-js` 需要。
- 本仓库作为 Posoco 的 `external/examples` 子模块开发，并在该工作区（`external/moon.work`）内构建。MoonBit 依赖经工作区 / mooncakes.io 解析。

### cetas-js —— 交互式终端 UI

```bash
cd external/examples/cetas-js
moon build --target js --release     # 构建 MoonBit 侧，产物在 _build/js/release/build/colmugx/cetas-js/lib/lib.js
bun install
bun run start              # 即 bun host.ts —— 完整 TUI
```

- 输入提示词后回车。工具调用实时流式呈现；助手回复按 Markdown 渲染。
- `/model` 打开模型选择器（`All` + 各 provider 标签页；←/→ 切换高亮模型的
  reasoning effort）。
- `/login` 通过 API key 或 OAuth 配置 provider
  （Codex/Kimi 目前走 device-code 流程，浮层会显示验证 URL 和代码）。
- `/help` 列出全部斜杠命令（`/clear`、`/new`、`/skills`、`/exit` 等）。

Provider 配置放在家目录下的 `.cetas/settings.json`。settings 对象会原样传给所选的 provider 扩展——Cetas 本身不解析 endpoint 或凭据。

### cetas-acp —— 从编辑器（Zed）驱动 Cetas

```bash
cd external/examples/cetas-acp
moon build --target native --release
# 二进制位于 _build/native/release/build/colmugx/cetas-acp/main/main.exe
```

请从项目根目录启动——工具在进程工作目录中执行，与 Zed 拉起 ACP agent 的方式一致。

在 Zed 设置里注册该二进制（最新 schema 见 [Zed 外部 agent 文档](https://zed.dev/docs/ai/external-agents)）：

```json
{
  "agent": {
    "acp_agents": {
      "cetas": {
        "command": "/absolute/path/to/external/_build/native/debug/build/colmugx/cetas-acp/main/main.exe",
        "args": []
      }
    }
  }
}
```

注意事项：

- 必须已配置模型 provider（`~/.cetas/settings.json` 或之前登录过 Cetas）——没有模型的 agent 无法服务任何 prompt，启动时会在 stderr 上明确报错并退出。
- 模型 / effort 选择通过 ACP config options（`session/set_config_option`）下发。选择是进程级的，并会持久化回 `~/.cetas/settings.json`。
- `CETAS_HOME` 可覆盖 Cetas 主目录（settings、凭据、sessions）；默认取 `HOME`。
- `<cwd>/.mcp.json`（覆盖 `~/.cetas/mcp.json`）声明的 MCP server 默认在第一轮才懒连接；设置 `CETAS_MCP_MODE=eager` 可改为启动时全部连接。

### 共享状态

两个宿主读写同一个 Cetas 主目录（默认 `~/.cetas/`）：`settings.json`（provider 配置 + 当前模型/effort）、凭据文件、`mcp.json`，以及 `sessions/`下的 JSONL 会话记录。
