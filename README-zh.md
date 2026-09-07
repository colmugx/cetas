# Cetas

**Cetas** 是一个构建在 [Posoco](https://github.com/colmugx/posoco) 之上的编程智能体。

> 无论你在哪里访问 Cetas，Cetas 都在那里。无论你怎么访问 Cetas，都是同一个 Cetas。
>
> Cetas 只有一个，抵达它的方式有很多。

### 目录结构

每个表示面组合的都是同一份 `cetas-core` 组装、同一个 Posoco `Agent`；
没有任何表示面自带 agent 循环逻辑，也没有任何表示面自定义身份。
新的表示面只是新的入口——不是新的 Cetas。

### 前置要求

- [MoonBit 工具链](https://docs.moonbitlang.com)（`moon`）。
- [Bun](https://bun.sh) —— 仅 `cetas-js` 需要。
- 本仓库位于 Posoco 工作区的 `external/cetas`，并在该工作区（`external/cetas/moon.work`）内构建。MoonBit 依赖经工作区 / mooncakes.io 解析。

### cetas-js —— 交互式终端 UI

```bash
cd cetas-js
bun run build
```

Provider 配置放在家目录下的 `.cetas/settings.json`。settings 对象会原样传给所选的 provider 扩展——Cetas 本身不解析 endpoint 或凭据。

### cetas-acp —— 从编辑器（Zed）驱动 Cetas

```bash
cd cetas-acp
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
        "command": "/absolute/path/to/cetas/_build/native/release/build/colmugx/cetas-acp/main/main.exe",
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

### 发版

发版通过在仓库根目录运行 `python3 scripts/release.py` 完成：它根据 git 历史建议版本号，打开编辑器填写发版说明，同步 `VERSION` 与各组件版本文件，更新 `CHANGELOG.md`，并创建 `cetas-vX.Y.Z` 标签。推送该标签会触发 `.github/workflows/release.yml`，为 darwin-arm64 / windows-x64 / linux-x64 构建 cetas-bun（内嵌 Bun 的二进制）与 cetas-acp（原生二进制），并连同 SHA256SUMS 一起附到 GitHub Release。`python3 scripts/release.py check` 是版本一致性门禁。

### 共享状态——"同一个 Cetas"今天意味着什么

所有表示面读写同一个 Cetas 主目录（默认 `~/.cetas/`）：`settings.json`
（provider 配置 + 当前模型/effort）、凭据文件、`mcp.json`，以及
`sessions/` 下的 JSONL 会话记录。这份共享主目录让上面的定义在今天就是
字面事实：登录一次，所有表示面都已登录；选一次模型，所有表示面都用它。
跨表示面续接同一场对话（跨宿主 session resume）是这个定义的下一块拼图。
