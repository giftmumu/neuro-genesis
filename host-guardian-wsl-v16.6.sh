#!/usr/bin/env bash
# =====================================================================
# NEURO-GENESIS WSL Host Guardian (v16.6 平台工程级基础设施标准化协议)
#
# Cloud-Native Platform Engineering Standard
#
# 架构哲学:
#   代码即数据，环境配置解耦
#   零依赖自举 (Bootstrap) · 全隔离 (Isolation) · 幂等防御 (Idempotent)
#   YAML 极简抽象 → 声明式部署 → 全局一劳永逸
#
# v16.6 增量 (相对 v16.5):
#   [NEW] 三层连通性预检: DNS → TCP → HTTP 逐层验证
#   [NEW] NO_PROXY 隔离域: 防止代理自环 + Docker 内网旁路
#   [NEW] apiBaseUrl: Claude Code config.json 原生端点注入
#   [NEW] 代理环检测: NO_PROXY 自动包含 CC-Switch 地址
#   [NEW] 四模式拓扑发现: Mirrored / NAT / DNS / Fallback
#   [NEW] TCP 探测三级降级: nc → /dev/tcp → python socket
#   [NEW] /etc/profile.d/ 中自动清理 CLAUDE_API_GATEWAY_URL 避免路径冲突
#   [NEW] Bashrc BEGIN/END 标记对幂等块，消除正则误删风险
#   [NEW] PyYAML 依赖显式声明与安装引导
#   [NEW] Sudo NOPASSWD 预检，无密码时优雅降级到用户级
#   [NEW] 原子文件写入 (os.replace) 防止中断损坏
#   [RETAINED] 全部 v16.5 工业级能力 (无损合并 / 多端口自愈 / 缓存治理)
#
# 交付物:
#   /etc/profile.d/neuro-genesis-ambient.sh  (系统全局，所有 shell/Docker 子进程继承)
#   ~/.config/claude-code/config.json         (无损合并，用户自定义永不丢失)
#
# 用法:
#   sudo bash host-guardian-wsl-v16.6.sh           # 首次 / 手动运行
#   # 推荐加入 crontab 实现守护自愈:
#   */2 * * * * /path/to/host-guardian-wsl-v16.6.sh >> /dev/null 2>&1
# =====================================================================
set -euo pipefail

# ─── 0. 常量声明 ────────────────────────────────────────────────────
readonly SCRIPT_NAME="host-guardian-wsl"
readonly SCRIPT_VERSION="16.6"
readonly CONFIG_FILE="/mnt/e/OpenClaw_Genesis/global-infra-v16.6.yaml"
readonly LOG_DIR="$HOME/.ai-infra/logs"
readonly LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"
readonly CLAUDE_CONFIG_DIR="$HOME/.config/claude-code"
readonly CLAUDE_CONFIG_FILE="$CLAUDE_CONFIG_DIR/config.json"
readonly PROFILE_D_FILE="/etc/profile.d/neuro-genesis-ambient.sh"
readonly BASHRC="$HOME/.bashrc"
readonly BLOCK_BEGIN="# >>> NEURO-GENESIS AMBIENT BEGIN >>>"
readonly BLOCK_END="# <<< NEURO-GENESIS AMBIENT END <<<"

# 全局默认值初始化 — 防止任何分支引用未定义变量
WINDOWS_IP=""
ACTIVE_PORT=0
PROXY_URL=""
NO_PROXY_LIST="localhost,127.0.0.1"
HEALTH_STATUS="OFFLINE"
HEALTH_DETAIL="no probe"
SUDO_OK=false

# ─── 1. 日志系统 ────────────────────────────────────────────────────
log() {
    local msg="$1"
    local level="${2:-INFO}"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    mkdir -p "$LOG_DIR"
    # Fix #8: 控制台输出走 stderr (fd 2)，而非 stdout (fd 1)
    # 原因: discover_windows_ip() 被 $(...) 捕获时，如果 log 写 stdout，
    #       日志文本会混入返回值，导致 WINDOWS_IP 变成多行垃圾字符串
    #       改为 stderr 后，$() 只捕获 echo "ip" 的纯数据输出
    printf "[%s] [%-5s] %s\n" "$ts" "$level" "$msg" >&2
    printf "[%s] [%-5s] %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── 2. 依赖检查 (含 PyYAML 显式声明) ─────────────────────────────
# Fix #1: PyYAML 是硬依赖，必须在启动时显式检测
check_dependencies() {
    local missing=()
    local install_hint=""

    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    # PyYAML: WSL 默认 Ubuntu 不自带此包
    if ! python3 -c "import yaml" 2>/dev/null; then
        missing+=("python3-yaml")
        install_hint="${install_hint}sudo apt install -y python3-yaml\n"
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log "Missing dependencies: ${missing[*]}" "FATAL"
        if [ -n "$install_hint" ]; then
            log "Install hint:\n$install_hint" "FATAL"
        fi
        exit 127
    fi

    # Fix #7: Sudo NOPASSWD 预检
    # 不阻塞流程，仅标记能力；写 /etc/profile.d/ 时按能力分流
    if sudo -n true 2>/dev/null; then
        SUDO_OK=true
        log "Sudo NOPASSWD: available" "DEBUG"
    else
        SUDO_OK=false
        log "Sudo NOPASSWD: not available (will fallback to user-level injection)" "WARN"
    fi

    log "Dependency check passed." "DEBUG"
}

# ─── 3. YAML 解析引擎 (Python safe_load — 零正则，像素级精确) ─────
get_yaml_value() {
    local parent="$1"
    local child="$2"
    local default="${3:-}"
    python3 <<PYEOF
import yaml, sys
try:
    with open('$CONFIG_FILE', 'r') as f:
        cfg = yaml.safe_load(f)
    val = cfg.get('$parent', {}).get('$child', '$default')
    if isinstance(val, list):
        print(' '.join(map(str, val)))
    elif val is None:
        print('')
    else:
        print(str(val))
except Exception:
    print('')
PYEOF
}

# ─── 4. TCP 探测工具 (nc → /dev/tcp → python socket 三级降级) ───
tcp_probe() {
    local host="$1"
    local port="$2"
    local timeout_sec="${3:-2}"

    # Level 1: netcat (最轻量)
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$timeout_sec" "$host" "$port" 2>/dev/null; then
            return 0
        fi
    fi

    # Level 2: bash 内建 /dev/tcp (无额外依赖)
    if timeout "$timeout_sec" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    fi

    # Level 3: python socket (终极降级)
    python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout($timeout_sec)
try:
    s.connect(('$host', $port))
    s.close()
except Exception:
    exit(1)
" 2>/dev/null && return 0

    return 1
}

# ─── 5. HTTP 应用层健康检测 ────────────────────────────────────────
# Fix #2: 不再对根路径 / 做误判
# 策略: 请求 /v1/models，接受 200/401/403 (401/403 说明服务在运行且鉴权生效)
#         任何非 000 响应码均表示"有个 HTTP 服务在应答"
#         但绝不因 HTTP 结果阻断管道 — TCP 可达即足够注入代理
http_probe() {
    local url="$1"
    local timeout_sec="${2:-3}"
    local code
    code=$(curl -s --connect-timeout "$timeout_sec" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    echo "$code"
}

# ─── 6. Windows 宿主 IP 动态发现 (四模式自适应) ───────────────────
discover_windows_ip() {
    local ip=""

    # Mode A: Mirrored 网络模式 (Windows 11 22H2+ .wslconfig networkMode=mirrored)
    #         localhost 直接映射 Windows 宿主端口，延迟最低
    if tcp_probe "127.0.0.1" "15721" "1"; then
        ip="127.0.0.1"
        log "Topology: Mirrored (localhost direct)" "DEBUG"
        echo "$ip"
        return 0
    fi

    # Mode B: NAT 默认网关模式 (传统 WSL2)
    #         从 ip route 推算宿主虚拟网关 IP
    local gw
    gw=$(ip route show default 2>/dev/null | awk '/default via/ {print $3; exit}')
    if [ -n "$gw" ] && tcp_probe "$gw" "15721" "1"; then
        ip="$gw"
        log "Topology: NAT gateway ($gw)" "DEBUG"
        echo "$ip"
        return 0
    fi

    # Mode C: DNS nameserver 推断
    #         WSL2 默认将宿主 IP 写入 /etc/resolv.conf
    local ns
    ns=$(grep -m1 'nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
    if [ -n "$ns" ] && [ "$ns" != "127.0.0.1" ] && [ "$ns" != "127.0.0.53" ]; then
        if tcp_probe "$ns" "15721" "1"; then
            ip="$ns"
            log "Topology: DNS nameserver ($ns)" "DEBUG"
            echo "$ip"
            return 0
        fi
    fi

    # Mode D: 最终降级 — 回退到 nameserver (TCP 未验证，仅 DNS 层面)
    if [ -n "$ns" ]; then
        ip="$ns"
        log "Topology: Fallback to nameserver ($ns) without TCP verification" "WARN"
    else
        ip="127.0.0.1"
        log "Topology: Hard fallback to localhost (no DNS hint)" "WARN"
    fi
    echo "$ip"
}

# ─── 7. Bashrc 幂等块管理 (BEGIN/END 标记对) ─────────────────────
# Fix #6: 用显式标记对替代正则猜测，彻底消除误删风险
bashrc_remove_old_block() {
    if [ ! -f "$BASHRC" ]; then
        return 0
    fi
    if ! grep -qF "$BLOCK_BEGIN" "$BASHRC" 2>/dev/null; then
        return 0
    fi
    # 用 Python 做精确的行级删除，不依赖正则
    python3 <<PYEOF
import os
path = '$BASHRC'
begin_marker = '$BLOCK_BEGIN'
end_marker   = '$BLOCK_END'
with open(path, 'r') as f:
    lines = f.readlines()
output = []
skipping = False
for line in lines:
    stripped = line.rstrip('\n')
    if stripped == begin_marker:
        skipping = True
        continue
    if stripped == end_marker:
        skipping = False
        continue
    if not skipping:
        output.append(line)
# 清理删除后可能产生的连续空行 (保留最多 1 个)
result = []
prev_blank = False
for line in output:
    is_blank = (line.strip() == '')
    if is_blank and prev_blank:
        continue
    result.append(line)
    prev_blank = is_blank
with open(path, 'w') as f:
    f.writelines(result)
PYEOF
    log "Bashrc old block removed (marker-pair strategy)." "DEBUG"
}

# ─── 8. 代理环境注入 (系统级 / 用户级 自动分流) ───────────────────
inject_proxy_env() {
    local target="$PROXY_URL"
    local no_proxy="$NO_PROXY_LIST"
    local ts
    ts=$(date -Iseconds 2>/dev/null || date "+%Y-%m-%dT%H:%M:%S%z")

    local env_content
    env_content=$(cat <<EOFILE
# ═══════════════════════════════════════════════════════════════
# NEURO-GENESIS Ambient Environment (auto-managed, DO NOT EDIT)
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Updated: ${ts}
# Health: ${HEALTH_STATUS} | Endpoint: ${target}
# ═══════════════════════════════════════════════════════════════
export HTTP_PROXY='${target}'
export HTTPS_PROXY='${target}'
export http_proxy='${target}'
export https_proxy='${target}'
export NO_PROXY='${no_proxy}'
export no_proxy='${no_proxy}'
# Fix #3: 仅保留 ANTHROPIC_BASE_URL，删除 CLAUDE_API_GATEWAY_URL
# 避免 Claude Code 将 /v1 拼接两次 (如 /v1/v1/messages)
export ANTHROPIC_BASE_URL='${target}'
export ANTHROPIC_API_KEY='sk-ant-ccswitch00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005555'
alias c='claude'
EOFILE
)

    if $SUDO_OK; then
        # ═══ 系统级注入: /etc/profile.d/ ═══
        # 覆盖所有用户、所有 shell (bash/zsh/sh)、Docker 子进程自动继承
        echo "$env_content" | sudo tee "$PROFILE_D_FILE" > /dev/null
        sudo chmod 644 "$PROFILE_D_FILE"
        log "System profile injected: $PROFILE_D_FILE" "INFO"
    else
        # ═══ 用户级降级: ~/.bashrc 标记块 ═══
        # 仅当前用户的 bash 生效，Docker 子进程不继承
        log "Sudo unavailable — falling back to user-level bashrc injection." "WARN"
        bashrc_remove_old_block
        {
            echo ""
            echo "$BLOCK_BEGIN"
            echo "$env_content"
            echo "$BLOCK_END"
            echo ""
        } >> "$BASHRC"
        log "User-level bashrc injected: $BASHRC" "INFO"
    fi
}

# ─── 9. 代理环境清理 (离线降级) ───────────────────────────────────
purge_proxy_env() {
    # 清理系统级
    if $SUDO_OK && [ -f "$PROFILE_D_FILE" ]; then
        sudo rm -f "$PROFILE_D_FILE"
        log "System profile purged: $PROFILE_D_FILE" "INFO"
    fi
    # 清理用户级
    bashrc_remove_old_block
    log "All proxy environment tokens purged. Safe Direct Mode." "INFO"
}

# ─── 10. Claude Code 配置 (无损 JSON 合并 + apiBaseUrl) ───────────
merge_claude_config() {
    mkdir -p "$CLAUDE_CONFIG_DIR"

    # 确定 apiBaseUrl (仅在上游存活时注入)
    local api_base_url=""
    if [ "$ACTIVE_PORT" -ne 0 ]; then
        api_base_url="http://${WINDOWS_IP}:${ACTIVE_PORT}"
    fi

    # Fix #5: Python stdout 直接输出，用管道捕获，无缓冲丢失
    local merge_report
    merge_report=$(python3 <<PYEOF
import json, os, sys

path = '$CLAUDE_CONFIG_FILE'
api_base = '$api_base_url'

# 管理字段清单: 这些字段由脚本管控，用户手动修改会在下次运行时被覆盖
managed_keys = {
    'oauthToken', 'hasCompletedOnboarding',
    'user_email', 'userEmail',
    'telemetry_enabled', 'telemetryEnabled',
    'apiBaseUrl',
}

# 构建管理字段底座
base = {
    'oauthToken': 'sk-ant-ccswitch-oauth-bypass-placeholder-token-00000000000000005555',
    'hasCompletedOnboarding': True,
    'user_email': '$USER_EMAIL',
    'userEmail': '$USER_EMAIL',
    'telemetry_enabled': $TELEMETRY_PY,
    'telemetryEnabled': $TELEMETRY_PY,
}

# v16.6 新增: apiBaseUrl 原生端点注入
if api_base:
    base['apiBaseUrl'] = api_base

# 无损合并: 读取现有配置，保留所有用户自定义字段 (MCP / 工具链 / 偏好)
preserved_count = 0
if os.path.exists(path):
    try:
        with open(path, 'r') as f:
            existing = json.load(f)
        if isinstance(existing, dict):
            for k, v in existing.items():
                if k not in managed_keys:
                    base[k] = v
                    preserved_count += 1
    except Exception as e:
        print(f'WARN: existing config unreadable ({e}), rebuilding from scratch')

# 原子写入: 先写 .tmp 再 replace，防止中断损坏
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(base, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, path)

print(f'Claude Code config merged: {preserved_count} user fields preserved')
if api_base:
    print(f'apiBaseUrl injected: {api_base}')
PYEOF
)

    # 将 Python 输出逐行写入日志
    while IFS= read -r line; do
        log "$line" "INFO"
    done <<< "$merge_report"

    # 缓存治理: 清理影子状态，防止旧缓存污染新配置
    rm -rf "${CLAUDE_CONFIG_DIR}/cache" "${CLAUDE_CONFIG_DIR}/state.json" 2>/dev/null || true
    log "Claude Code cache purged for clean state." "DEBUG"
}

# ═══════════════════════════════════════════════════════════════════
#                          主 逻 辑
# ═══════════════════════════════════════════════════════════════════
main() {
    log "============================================================"
    log "  HOST GUARDIAN (WSL v${SCRIPT_VERSION}) Platform Engineering"
    log "============================================================"

    # ── Phase 0: 依赖检查 ────────────────────────────────────────
    check_dependencies

    # ── Phase 1: 配置加载 ────────────────────────────────────────
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Config not found: $CONFIG_FILE" "FATAL"
        exit 1
    fi
    log "Config loaded: $CONFIG_FILE" "INFO"

    USER_EMAIL=$(get_yaml_value "ai_agent_auth" "user_email" "tutu@neuro-genesis.local")
    [ -z "$USER_EMAIL" ] && USER_EMAIL="tutu@neuro-genesis.local"
    TELEMETRY_RAW=$(get_yaml_value "claude_code" "telemetry_enabled" "false")
    [ "$TELEMETRY_RAW" = "true" ] && TELEMETRY_PY="True" || TELEMETRY_PY="False"
    PROBE_PORTS=$(get_yaml_value "infra_network" "probe_ports" "15721 4386 7890 10809")
    [ -z "$PROBE_PORTS" ] && PROBE_PORTS="15721 4386 7890 10809"
    NO_PROXY_EXTRA=$(get_yaml_value "infra_network" "no_proxy_extra" "")

    log "Facts: email=$USER_EMAIL telemetry=$TELEMETRY_RAW ports=$PROBE_PORTS" "DEBUG"

    # ── Phase 2: 拓扑发现 ────────────────────────────────────────
    WINDOWS_IP=$(discover_windows_ip)
    log "Windows host IP: $WINDOWS_IP" "INFO"

    # ── Phase 3: 多端口 TCP 活性扫描 ─────────────────────────────
    for PORT in $PROBE_PORTS; do
        if tcp_probe "$WINDOWS_IP" "$PORT" "2"; then
            ACTIVE_PORT=$PORT
            log "Port $PORT on $WINDOWS_IP: TCP reachable" "INFO"
            break
        fi
    done

    # ── Phase 4: 三层连通性预检 ──────────────────────────────────
    if [ "$ACTIVE_PORT" -ne 0 ]; then
        PROXY_URL="http://${WINDOWS_IP}:${ACTIVE_PORT}"

        # L1 DNS: 系统解析能力
        DNS_STATUS="UNKNOWN"
        if python3 -c "import socket; socket.gethostbyname('dns.google')" 2>/dev/null; then
            DNS_STATUS="OK"
        else
            DNS_STATUS="FAIL"
        fi

        # L2 TCP: 已在 Phase 3 验证
        TCP_STATUS="OK"

        # L3 HTTP: 应用层探测 (Best-effort，不阻断管道)
        # Fix #2: 使用 /v1/models，接受 200/401/403 均为"服务在运行"
        HTTP_CODE=$(http_probe "http://${WINDOWS_IP}:${ACTIVE_PORT}/v1/models" "3")
        case "$HTTP_CODE" in
            200|401|403) HTTP_STATUS="OK ($HTTP_CODE)" ;;
            404)          HTTP_STATUS="ALIVE ($HTTP_CODE)" ;;
            "000")        HTTP_STATUS="NO_RESPONSE" ;;
            *)            HTTP_STATUS="ALIVE ($HTTP_CODE)" ;;
        esac

        # 健康状态判定: TCP 可达即足够注入代理，HTTP 为附加信息
        HEALTH_STATUS="ALIVE"
        HEALTH_DETAIL="DNS=${DNS_STATUS} TCP=${TCP_STATUS} HTTP=${HTTP_STATUS}"

        if [ "$HTTP_STATUS" != "NO_RESPONSE" ]; then
            HEALTH_STATUS="VERIFIED"
        fi

        log "Pre-check: $HEALTH_DETAIL" "INFO"
    else
        HEALTH_STATUS="OFFLINE"
        HEALTH_DETAIL="all ports unreachable on $WINDOWS_IP"
        log "Pre-check: $HEALTH_DETAIL" "WARN"
    fi

    # ── Phase 5: 代理环境注入 / 降级 ─────────────────────────────
    if [ "$ACTIVE_PORT" -ne 0 ]; then
        # Fix #4 (完整版): NO_PROXY 构建
        # 关键: CC-Switch 自身地址必须排除，否则 HTTP 客户端会形成代理自环
        NO_PROXY_LIST="localhost,127.0.0.1,${WINDOWS_IP}"
        NO_PROXY_LIST="${NO_PROXY_LIST},.local,host.docker.internal"
        NO_PROXY_LIST="${NO_PROXY_LIST},10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
        # 追加用户在 YAML 中声明的额外排除域
        if [ -n "$NO_PROXY_EXTRA" ]; then
            NO_PROXY_LIST="${NO_PROXY_LIST},${NO_PROXY_EXTRA}"
        fi

        log "Proxy injection: $PROXY_URL" "INFO"
        log "NO_PROXY isolation: $NO_PROXY_LIST" "DEBUG"

        inject_proxy_env
    else
        # 优雅降级: 上游全灭，清理所有代理变量，确保业务不断流
        log "Upstream OFFLINE. Purging proxy tokens. Safe Direct Mode." "WARN"
        NO_PROXY_LIST="localhost,127.0.0.1,.local"
        purge_proxy_env
    fi

    # ── Phase 6: Claude Code 配置合并 ─────────────────────────────
    merge_claude_config

    # ── Phase 7: 健康报告 ─────────────────────────────────────────
    local no_proxy_count
    no_proxy_count=$(echo "$NO_PROXY_LIST" | tr ',' '\n' | grep -c . || true)

    log "+------------------------------------------------------------+"
    log "|                  HEALTH REPORT v${SCRIPT_VERSION}                      |"
    log "+------------------------------------------------------------+"
    log "|  Windows Host    : $WINDOWS_IP"
    log "|  Active Port     : $([ "$ACTIVE_PORT" -ne 0 ] && echo "$ACTIVE_PORT" || echo "NONE (direct)")"
    log "|  Proxy URL       : $([ -n "$PROXY_URL" ] && echo "$PROXY_URL" || echo "N/A (direct mode)")"
    log "|  Health Status   : $HEALTH_STATUS"
    log "|  Health Detail   : $HEALTH_DETAIL"
    log "|  NO_PROXY Domains: $no_proxy_count"
    log "|  Injection Level : $([ "$SUDO_OK" = true ] && echo "SYSTEM (/etc/profile.d/)" || echo "USER (~/.bashrc)")"
    log "|  Claude Config   : $CLAUDE_CONFIG_FILE"
    log "+------------------------------------------------------------+"

    log "HOST GUARDIAN (WSL v${SCRIPT_VERSION}) COMPLETED" "INFO"
}

main "$@"
