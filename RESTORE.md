# NEURO-GENESIS 完整复刻指南

> 从零搭建：Windows + WSL2 + Docker + OpenClaw + CC-Switch + DeepSeek
>
> 适用场景：换新电脑 / 环境重建 / 给别人复刻

---

## 目录

1. [前置依赖安装](#1-前置依赖安装)
2. [WSL2 环境配置](#2-wsl2-环境配置)
3. [Docker Desktop 安装](#3-docker-desktop-安装)
4. [CC-Switch 安装与配置](#4-cc-switch-安装与配置)
5. [NEURO-GENESIS 项目部署](#5-neuro-genesis-项目部署)
6. [Claude Code 配置](#6-claude-code-配置)
7. [验证全链路](#7-验证全链路)
8. [故障排查](#8-故障排查)
9. [架构总览](#9-架构总览)

---

## 1. 前置依赖安装

### 1.1 Windows 系统要求

- Windows 11（推荐）或 Windows 10 22H2+
- CPU 支持虚拟化（BIOS 中开启 VT-x/AMD-V）
- 16GB+ RAM（推荐 32GB）

### 1.2 下载安装包

| 组件 | 下载地址 | 版本参考 |
|------|---------|---------|
| WSL2 | `wsl --install` (管理员 PowerShell) | Ubuntu 24.04 LTS |
| Docker Desktop | https://www.docker.com/products/docker-desktop/ | v27+ |
| CC-Switch | https://github.com/farion1231/cc-switch/releases | v3.16.3 |
| VS Code | https://code.visualstudio.com/Download | v1.125+ |
| Ollama | https://ollama.com/download | v0.6+ |

### 1.3 安装 WSL2

```powershell
# 管理员 PowerShell
wsl --install -d Ubuntu-24.04
wsl --set-default-version 2

# 重启后设置用户名密码，然后：
sudo apt update && sudo apt upgrade -y
```

### 1.4 安装 Docker Desktop

1. 下载 Docker Desktop for Windows 并安装
2. 设置 → Resources → WSL Integration → 启用 Ubuntu-24.04
3. Apply & Restart

### 1.5 安装 Ollama（Windows 版）

下载安装后拉取本地模型：
```powershell
ollama pull qwen:7b-chat-q4_0
```

---

## 2. WSL2 环境配置

### 2.1 配置 .bashrc

在 WSL2 中（`~/.bashrc`），添加以下代理和 API 路由配置：

```bash
# =============================================
# CC-Switch / Claude Code 路由配置
# =============================================
# Claude Code → CC-Switch 的 Anthropic 入站端点
export ANTHROPIC_BASE_URL="http://127.0.0.1:15721"
# CC-Switch 路由密钥（不是真实 API key，用于标识路由）
export ANTHROPIC_API_KEY="sk-ant-ccswitch<...>"

# Claude Code 的 HTTP 代理指向 CC-Switch
export HTTP_PROXY="http://127.0.0.1:15721"
export HTTPS_PROXY="http://127.0.0.1:15721"
export http_proxy="http://127.0.0.1:15721"
export https_proxy="http://127.0.0.1:15721"
export no_proxy="localhost,127.0.0.1"

# 本地容器不经过代理
export NO_PROXY="localhost,127.0.0.1,0.0.0.0,openclaw-gateway,.local,.internal,host.docker.internal"
```

> **注意**: `ANTHROPIC_API_KEY` 的值需要从 CC-Switch 数据库获取。
> 安装 CC-Switch 后在 Web 界面中查看 Claude Code 配置页面的 API Key。

### 2.2 验证 WSL2 网络

```bash
# 确认 WSL2 能联通外网
ping -c 1 8.8.8.8
curl -s https://api.deepseek.com | head -5
```

---

## 3. Docker Desktop 安装

### 3.1 配置 Docker 资源

Docker Desktop → Settings:
- **Resources → Advanced**: CPUs ≥ 4, Memory ≥ 8GB, Swap ≥ 2GB
- **Resources → WSL Integration**: 启用你的 Ubuntu 发行版
- **Docker Engine**: 确保 `"host"` 网络驱动可用（默认 enabled）

### 3.2 验证 Docker

```bash
docker run --rm hello-world
docker compose version
```

---

## 4. CC-Switch 安装与配置

### 4.1 安装 CC-Switch

Windows 端：

1. 运行 `CC-Switch-v3.16.3-Windows.msi` 或解压 `CC-Switch-v3.16.3-Windows-Portable.zip`
2. 启动 CC-Switch（双击 `cc-switch.exe`）
3. 浏览器打开 http://localhost:15721 进入 Web 界面

### 4.2 配置 CC-Switch

#### 4.2.1 Provider Endpoints

在 CC-Switch Web 界面中配置：

| 字段 | 值 |
|------|-----|
| Provider Name | DeepSeek |
| API Base URL | `https://api.deepseek.com/v1` |
| API Key | `sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`（你的真实 DeepSeek key） |
| API Format | `openai_chat` |

> 注意：该真实 API key 仅保存在 CC-Switch 的 SQLite 数据库中，
> **不**出现在任何配置文件中。这是"方案B"的核心安全机制。

#### 4.2.2 Provider Cards

添加自定义 Provider Card（用于 OpenClaw 路由）：

- **名称**: `deepseek-1m`
- **应用类型**: `openclaw`
- **Base URL**: `https://api.deepseek.com/v1`
- **API**: `openai-completions`
- **端点**: `https://api.deepseek.com/v1/chat/completions`
- **端点元数据**: `{"isFullUrl":false, "apiFormat":"openai_chat", "endpointAutoSelect":true}`

#### 4.2.3 Proxy 配置

| 字段 | claude | codex |
|------|--------|-------|
| enabled | 1 | 1 |
| 监听地址 | 0.0.0.0 | 0.0.0.0 |
| 监听端口 | 15721 | 15721 |
| 超时 | 600s | 600s |
| 重试 | 6 | 3 |

> **关键**: codex proxy 用于处理 OpenAI Chat Completions 格式的入站请求。
> OpenClaw 使用 `/v1/chat/completions` 路径连接到 CC-Switch，
> CC-Switch 内部通过 codex 路由处理该格式。

### 4.3 验证 CC-Switch

```bash
# WSL2 中验证
curl -s -w "\nHTTP:%{http_code}" \
  http://127.0.0.1:15721/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-dummy-proxy-routed" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
```

应返回 HTTP 200 + DeepSeek 响应。

---

## 5. NEURO-GENESIS 项目部署

### 5.1 克隆项目

```bash
git clone https://github.com/giftmumu/neuro-genesis.git
cd neuro-genesis
```

### 5.2 选择版本

项目包含多个 docker-compose 版本：

| 文件 | 说明 |
|------|------|
| `docker-compose.yml` | v9.0 — bridge 网络版（带 Privoxy 代理链） |
| **`docker-compose-v9.2.yml`** | **✅ v9.2 推荐 — host 网络版，直连 CC-Switch** |

推荐使用 `docker-compose-v9.2.yml`。

### 5.3 目录结构

```
neuro-genesis/
├── docker-compose-v9.2.yml     # 主编排文件
├── config/
│   ├── openclaw.json            # OpenClaw 模型/Agent 配置
│   ├── gateway.json             # 网关路由配置
│   ├── config.json              # OpenClaw 基础配置
│   └── ...
├── global-infra-v16.6.2.yaml   # 全局基础设施架构定义
├── host-guardian-wsl-v16.6.2.sh  # WSL2 守护脚本
├── host-guardian-win-v16.6.2.ps1 # Windows 守护脚本
├── setup-docker-proxy.sh       # Docker 代理配置脚本
└── setup-windows-proxy.ps1     # Windows 代理配置脚本
```

### 5.4 启动服务

```bash
# 创建 docker network
docker network create openclaw_genesis_neuro-net 2>/dev/null || true

# 启动所有服务
docker compose -f docker-compose-v9.2.yml up -d

# 检查状态
docker ps

# 查看日志
docker logs openclaw-gateway
```

### 5.5 架构拓扑

```
Windows 宿主机
├── CC-Switch (0.0.0.0:15721)          ← API 密钥统一替换层
└── WSL2
    ├── OpenClaw Gateway (host 网络)    ← host 网络直连 localhost
    │   └── → 127.0.0.1:15721 → CC-Switch → api.deepseek.com
    │
    ├── network-guardian (Privoxy)     ← 其他容器的 HTTP 代理链
    │   └── host.docker.internal:PORT  → Clash/CC-Switch
    │
    ├── emotion-engine (8001)           ← 情感分析引擎
    ├── visual-server (8088)            ← 视觉服务器
    ├── ollama (11434)                  ← 本地 LLM (fallback)
    ├── prometheus (9090)               ← 监控
    └── grafana (3001)                  ← 可视化
```

### 5.6 为什么 OpenClaw 使用 host 网络？

**关键发现**: Docker Desktop for Windows（WSL2 后端）的 `host.docker.internal`
DNS 在 HTTP 层存在连接重置 bug — TCP 连接可以建立（nc 确认端口开放），
但 HTTP 请求发送后立即收到 RST（socket hang up）。

**解决方案**: `network_mode: "host"` 让容器共享 WSL2 的网络命名空间，
直接通过 `127.0.0.1:15721` 访问 CC-Switch，完全绕过 `host.docker.internal`。

> 注意: host 网络模式仅用于 OpenClaw。其他容器（emotion-engine、visual-server 等）
> 仍然使用 bridge 网络（neuro-net）通过 Privoxy 代理访问外网。

---

## 6. Claude Code 配置

### 6.1 安装 Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

### 6.2 配置路由

确保 `.bashrc` 中已设置（见[2.1](#21-配置-bashrc)）：

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:15721"
export ANTHROPIC_API_KEY="sk-ant-ccswitch<...>"
```

### 6.3 验证

```bash
claude --version
# 发送测试消息
echo "hi" | claude --model deepseek-v4-flash --max-tokens 10
```

---

## 7. 验证全链路

### 7.1 逐层验证

```bash
# 1. WSL2 → CC-Switch → DeepSeek
curl -s -w "\nHTTP:%{http_code}" \
  http://127.0.0.1:15721/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-dummy-proxy-routed" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'

# 2. Docker 容器 → CC-Switch（host 网络模式）
docker run --rm --network host node:22-bookworm node -e '
const http = require("http");
const data = JSON.stringify({model:"deepseek-v4-flash",messages:[{role:"user",content:"hi"}],max_tokens:10});
const req = http.request({hostname:"127.0.0.1",port:15721,path:"/v1/chat/completions",method:"POST",
  headers:{"Content-Type":"application/json","Authorization":"Bearer sk-dummy-proxy-routed",
  "Content-Length":Buffer.byteLength(data)},timeout:30000}, (res) => {
  let b=""; res.on("data",c=>b+=c); res.on("end",()=>console.log("HTTP",res.statusCode,b.substring(0,100)));
});
req.on("error",e=>console.error("Error:",e.message)); req.write(data); req.end();
'

# 3. OpenClaw Web UI
浏览器打开 http://localhost:18789

# 4. CC-Switch 请求日志
# 在 CC-Switch Web 界面查看请求记录
```

### 7.2 预期结果

| 测试 | 预期 | 验证状态 |
|------|------|---------|
| WSL2 curl → CC-Switch → DeepSeek | HTTP 200 + JSON 响应 | ✅ 已验证 |
| Docker host 网络 → CC-Switch | HTTP 200 + JSON 响应 | ✅ 已验证 |
| OpenClaw Web UI 可访问 | 页面正常加载 | ✅ 已验证 |
| OpenClaw → CC-Switch 对话 | 返回 AI 回复 | ✅ 已验证 |
| Ollama fallback 可用 | localhost:11434 响应 | ✅ 已验证 |

---

## 8. 故障排查

### 8.1 CC-Switch 无法连接

```bash
# 检查 CC-Switch 是否在 Windows 上运行
# Windows: netstat -ano | findstr "15721"
# WSL2:
curl http://127.0.0.1:15721/v1/chat/completions -X POST -H "Content-Type: application/json" -d '{}'

# 如果返回 404：确认 CC-Switch 正在运行且 proxy 已启用
# 如果返回连接拒绝：确认 CC-Switch 监听在 0.0.0.0 而非 127.0.0.1
```

### 8.2 Docker 容器无法连接 CC-Switch

```bash
# 确认容器使用 host 网络模式
docker inspect openclaw-gateway --format '{{.HostConfig.NetworkMode}}'
# 应该输出 "host"

# 测试容器内连通性
docker run --rm --network host alpine:3.20 sh -c '
  wget -q -O - --timeout=10 \
    --header="Content-Type: application/json" \
    --header="Authorization: Bearer sk-dummy-proxy-routed" \
    --post-data="{\"model\":\"deepseek-v4-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":3}" \
    http://127.0.0.1:15721/v1/chat/completions
'
```

### 8.3 代理环境变量冲突

**症状**: CC-Switch 主页面提示"检测到系统环境变量冲突"

**原因**: WSL2 的 `.bashrc` 中设置了 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_API_KEY`，
Claude Code 通过这些变量连接到 CC-Switch。CC-Switch 检测到这些环境变量与自身配置可能冲突。

**处理**: 这是正常运行状态，无需处理。环境变量用于 Claude Code → CC-Switch 路由，
CC-Switch 自身不会读取这些 Windows 环境变量。

### 8.4 OpenClaw 容器日志

```bash
docker logs openclaw-gateway

# 常见日志解读：
# "startup model warmup failed" → 秘密目录权限问题，不影响运行时
# "model configured, enabled automatically" → 配置正确加载
# "http server listening (N plugins: ...)" → 启动成功
```

---

## 9. 架构总览

### 9.1 数据流

```
[用户] → http://localhost:18789 → OpenClaw Gateway (host 网络)
  → http://127.0.0.1:15721/v1/chat/completions → CC-Switch (Windows)
    → API key 替换（数据库中的真实 key）
    → https://api.deepseek.com/v1/chat/completions → DeepSeek V4

[Claude Code CLI] → WSL2 环境变量路由
  → ANTHROPIC_BASE_URL=http://127.0.0.1:15721
  → CC-Switch Anthropic 入站端点 → DeepSeek
```

### 9.2 安全设计（方案B）

| 层 | API Key | 存储位置 | 是否可上传 GitHub |
|----|---------|---------|----------------|
| OpenClaw config | `sk-dummy-proxy-routed` | `config/openclaw.json` | ✅ 安全（假 key） |
| 容器内环境变量 | 未设置 | 无 | ✅ 安全 |
| CC-Switch 数据库 | 真实 DeepSeek key | Windows `%USERPROFILE%\.cc-switch\cc-switch.db` | ❌ 不提交 |
| Claude Code .bashrc | CC-Switch 路由 key | WSL2 `~/.bashrc` | ⚠️ 建议手动 masked |

### 9.3 组件关系

```
                    neuro-net (bridge)
                    ┌──────────────────────────────────┐
                    │  network-guardian (Privoxy:80)    │
                    │  emotion-engine (8001)             │
                    │  visual-server (8088)              │
                    │  ollama (11434)                    │
                    │  prometheus (9090)                 │
                    │  grafana (3001)                    │
                    └──────────────────────────────────┘
                                │ HTTP_PROXY
                                ▼
                    host.docker.internal:PORT
                    (Clash / CC-Switch / 梯子)

                    host 网络
                    ┌──────────────────────────────────┐
                    │  openclaw-gateway (18789)          │
                    │  → 127.0.0.1:15721 (CC-Switch)     │
                    │  → 127.0.0.1:11434 (Ollama)        │
                    └──────────────────────────────────┘
```

### 9.4 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v9.2 | 2026-06-27 | OpenClaw host 网络模式，直连 CC-Switch |
| v9.1 | 2026-06-25 | Healthcheck 参数优化 |
| v9.0 | 2026-06-22 | 初始全解耦算力发现网格 |

---

> **最后更新**: 2026-06-27
>
> **本指南配套备份**: `_backup/` 目录包含完整的环境配置快照
