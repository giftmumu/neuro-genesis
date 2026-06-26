# =====================================================================
# NEURO-GENESIS Windows Host Guardian (v16.6.2 平台工程级基础设施标准化协议)
#
# Cloud-Native Platform Engineering Standard
#
# 架构哲学:
#   代码即数据，环境配置解耦
#   零依赖自举 (Bootstrap) · 全隔离 (Isolation) · 幂等防御 (Idempotent)
#   YAML 极简抽象 → 声明式部署 → 全局一劳永逸
#
# ═══════════════════════════════════════════════════════════════════
#  CC-Switch 在拓扑中的角色 (经 GitHub README + 官方文档核实)
# ═══════════════════════════════════════════════════════════════════
#   CC-Switch = 本地路由 + 协议翻译网关 (不是 HTTP outbound proxy)
#   入站: Anthropic Messages  POST /v1/messages
#   出站: OpenAI Chat Completions  POST /v1/chat/completions
#   端点:  /v1/messages + /v1/chat/completions (不实现 /v1/models)
#   能力: 热切换 · 故障转移 · 熔断器 · 健康监控 · 请求矫正 · 应用级接管
#   路由: 按 Provider Card → DeepSeek(国内直连) / Claude(经 Clash 7890 出海)
# ═══════════════════════════════════════════════════════════════════
#
# v16.6.2 增量 (相对 v16.6.1):
#   [FIX]  探测端点 /v1/models → /v1/messages (CC-Switch 实际实现的端点)
#   [FIX]  /v1/messages 返回 401 = VERIFIED (鉴权生效 = 服务正常)
#   [FIX]  /v1/messages 返回 404 = DEGRADED (端点存在但路由异常)
#   [RETAINED] 全部 v16.6.1 修复 (YAML 列表崩溃 / 环境变量数组 / 幽灵进程)
#
# 交付物:
#   %USERPROFILE%\.config\claude-code\config.json  (无损合并)
#   Windows User 环境变量                          (持久化，新进程自动继承)
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File host-guardian-win-v16.6.2.ps1
#   # 推荐加入 Task Scheduler 实现守护自愈 (每 2 分钟)
# =====================================================================

# ─── 0. 严格模式 ──────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ─── 1. 常量声明 ──────────────────────────────────────────────────
$SCRIPT_VERSION = "16.6.2"
$CONFIG_FILE = "E:\OpenClaw_Genesis\global-infra-v16.6.2.yaml"
$LOG_ROOT = "E:\OpenClaw_Genesis\logs"
$LOG_FILE = "$LOG_ROOT\host-guardian-win.log"
$ClaudeConfigDir = Join-Path $env:USERPROFILE ".config\claude-code"
$ClaudeConfigFile = Join-Path $ClaudeConfigDir "config.json"

# 全局状态 — 所有分支路径赋值前保证有默认值
$ActivePort = 0
$PortAlive = $false
$ProxyUrl = ""
$NoProxyList = "localhost,127.0.0.1"
$HealthStatus = "OFFLINE"
$HealthDetail = "not probed"
$ProxyEnvInject = $true
$PreservedFieldCount = 0

# Claude Code config.json 中由脚本管控的字段集合
# 任何在此列表中的字段，脚本运行时会被覆盖为事实源值
# 不在列表中的字段 (如 MCP 服务、自定义工具链) 永远保留
$script:ManagedKeys = @(
    "user_email", "userEmail",
    "telemetry_enabled", "telemetryEnabled",
    "hasCompletedOnboarding",
    "oauthToken",
    "apiBaseUrl"
)

# ─── 2. 日志系统 (双通道: 控制台 + 文件) ─────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp] [$Level] $Message"
    Write-Host $Entry
    $LogDir = Split-Path $LOG_FILE -Parent
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    Add-Content -Path $LOG_FILE -Value $Entry -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ─── 3. YAML 解析引擎 (零依赖，纯 PowerShell 原生正则) ────────────
# 支持嵌套路径: Get-YamlValue "infra_network" "probe_ports"
#           或扁平:   Get-YamlValue "" "daemon_enabled"
function Get-YamlValue {
    param($FilePath, $Section = "", $Key, $Default = $null)
    if (-not (Test-Path $FilePath)) { return $Default }

    $Lines = Get-Content -Path $FilePath -ErrorAction SilentlyContinue
    $CurrentSection = ""
    foreach ($Line in $Lines) {
        if ($Line -match '^\s*$' -or $Line -match '^\s*#') { continue }
        if ($Line -match '^(\S[^:]*)\s*:\s*$') { $CurrentSection = $Matches[1].Trim(); continue }
        if ($Line -match '^\s*(?:["'']?(\S+?)["'']?)\s*:\s*(?:["'']?(.*?)["'']?)\s*(?:#.*)?$') {
            $FoundKey = $Matches[1].Trim()
            $FoundValue = $Matches[2].Trim()
            if ([string]::IsNullOrEmpty($Section)) {
                if ($FoundKey -eq $Key) { return Expand-YamlValue $FoundValue }
            } else {
                if ($CurrentSection -eq $Section -and $FoundKey -eq $Key) { return Expand-YamlValue $FoundValue }
            }
        }
    }
    return $Default
}

function Expand-YamlValue {
    param([string]$Raw)
    if ($null -eq $Raw) { return $null }
    $Raw = $Raw.Trim()
    if ($Raw -eq 'true') { return "true" }
    if ($Raw -eq 'false') { return "false" }
    if ($Raw -match '^\[(.*)\]$') {
        $Items = $Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ -ne '' }
        return ,$Items
    }
    return $Raw
}

# ─── 4. TCP 异步探测 (保留 v16.5 原版异步机制，零修改) ────────────
function Test-TcpPort {
    param($HostName = "127.0.0.1", $Port = 15721, $TimeoutMs = 1000)
    try {
        $TcpClient = New-Object System.Net.Sockets.TcpClient
        $AsyncResult = $TcpClient.BeginConnect($HostName, $Port, $null, $null)
        if ($AsyncResult.AsyncWaitHandle.WaitOne($TimeoutMs) -and $TcpClient.Connected) {
            $TcpClient.EndConnect($AsyncResult)
            $TcpClient.Close()
            return $true
        }
        if ($null -ne $TcpClient) { $TcpClient.Close() }
    } catch { }
    return $false
}

# ─── 5. HTTP 应用层健康检测 ────────────────────────────────────────
# v16.6.2: 使用 /v1/messages 端点 (CC-Switch 实际实现的入站端点)
#   CC-Switch v3.16.3 端点:
#     /v1/messages           — Anthropic Messages 入站 (Claude Code 使用此端点)
#     /v1/chat/completions   — OpenAI Chat Completions 入站
#     /v1/models             — 不实现 (404)
#
#   状态判定矩阵:
#     200/401/403 → VERIFIED   (服务在运行且鉴权生效，401/403 是 CC-Switch 对无效 token 的正常响应)
#     404        → DEGRADED    (端点不应 404，说明路由异常)
#     5xx        → DEGRADED    (服务在运行但内部错误)
#     连接失败    → OFFLINE     (TCP 可达但 HTTP 无响应 = 服务可能在启动中)
function Test-HttpEndpoint {
    param($Url = "http://127.0.0.1:15721/v1/messages", $TimeoutSec = 3)
    try {
        $Response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return @{ StatusCode = [int]$Response.StatusCode; IsAlive = $true; Degraded = $false }
    } catch {
        if ($_.Exception.Response) {
            $Code = [int]$_.Exception.Response.StatusCode
            if ($Code -ge 500) {
                # 5xx: 服务在运行但内部错误
                return @{ StatusCode = $Code; IsAlive = $true; Degraded = $true }
            }
            if ($Code -eq 404) {
                # 404 on /v1/messages: 不应发生 (CC-Switch 实现此端点)，标记 DEGRADED
                return @{ StatusCode = $Code; IsAlive = $true; Degraded = $true }
            }
            # 401/403: 鉴权生效 = 服务正常运行 (CC-Switch 对无效 API key 的正常响应)
            return @{ StatusCode = $Code; IsAlive = $true; Degraded = $false }
        }
        return @{ StatusCode = 0; IsAlive = $false; Degraded = $false }
    }
}

# ─── 6. DNS 解析预检 ──────────────────────────────────────────────
function Test-DnsResolution {
    param($HostName = "dns.google")
    try {
        $Result = [System.Net.Dns]::GetHostAddresses($HostName)
        return ($null -ne $Result -and $Result.Count -gt 0)
    } catch { return $false }
}

# ─── 7. 环境变量管理 (幂等注入 / 全量清除) ────────────────────────
# User 级: 写入注册表，新进程自动继承
# Process 级: 当前 PowerShell 会话即时生效

$ProxyEnvVars = @(
    "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
    "NO_PROXY", "no_proxy",
    "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY"
)

function Set-ProxyEnvironment {
    param($ProxyUrl, $NoProxy, $ApiKey)
    # 使用数组替代哈希表: PowerShell 哈希表大小写不敏感，
    # "HTTP_PROXY" 和 "http_proxy" 会被视为同一个键导致解析崩溃
    $EnvVars = @(
        @{Name="HTTP_PROXY"; Value=$ProxyUrl},
        @{Name="HTTPS_PROXY"; Value=$ProxyUrl},
        @{Name="http_proxy"; Value=$ProxyUrl},
        @{Name="https_proxy"; Value=$ProxyUrl},
        @{Name="NO_PROXY"; Value=$NoProxy},
        @{Name="no_proxy"; Value=$NoProxy},
        @{Name="ANTHROPIC_BASE_URL"; Value=$ProxyUrl},
        @{Name="ANTHROPIC_API_KEY"; Value=$ApiKey}
    )
    foreach ($Var in $EnvVars) {
        [Environment]::SetEnvironmentVariable($Var.Name, $Var.Value, "User")
        Set-Item -Path "Env:\$($Var.Name)" -Value $Var.Value -ErrorAction SilentlyContinue
    }
    Write-Log "Environment injected: $ProxyUrl (User-level persistent)" "INFO"
}

function Clear-ProxyEnvironment {
    foreach ($VarName in $ProxyEnvVars) {
        [Environment]::SetEnvironmentVariable($VarName, $null, "User")
        Remove-Item -Path "Env:\$VarName" -ErrorAction SilentlyContinue
    }
    Write-Log "All proxy environment variables purged (User + Process)." "INFO"
}

# ─── 8. Claude Code 配置 (无损 JSON 合并) ─────────────────────────
function Merge-ClaudeConfig {
    param($ConfigPath, $UserEmail, [bool]$Telemetry, $ApiBaseUrl)
    $ManagedKeys = $script:ManagedKeys
    if (-not (Test-Path (Split-Path $ConfigPath -Parent))) {
        New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath -Parent) | Out-Null
    }
    $Base = [ordered]@{
        oauthToken            = "sk-ant-ccswitch-oauth-bypass-placeholder-token-00000000000000005555"
        hasCompletedOnboarding = $true
        user_email            = if ($UserEmail) { $UserEmail } else { "user@local" }
        userEmail             = if ($UserEmail) { $UserEmail } else { "user@local" }
        telemetry_enabled     = $Telemetry
        telemetryEnabled      = $Telemetry
    }
    if (-not [string]::IsNullOrEmpty($ApiBaseUrl)) { $Base["apiBaseUrl"] = $ApiBaseUrl }
    $PreservedCount = 0
    if (Test-Path $ConfigPath) {
        try {
            $ExistingRaw = Get-Content -Raw -Path $ConfigPath -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrEmpty($ExistingRaw)) {
                $Existing = ConvertFrom-Json $ExistingRaw -ErrorAction Stop
                if ($null -ne $Existing -and $Existing -is [PSCustomObject]) {
                    foreach ($Prop in $Existing.PSObject.Properties) {
                        if ($ManagedKeys -contains $Prop.Name) { continue }
                        $Base[$Prop.Name] = $Prop.Value
                        $PreservedCount++
                    }
                    Write-Log "Claude Code config: $PreservedCount user fields preserved (lossless)." "INFO"
                }
            }
        } catch { Write-Log "Existing Claude config unreadable, rebuilding from scratch: $_" "WARN" }
    }
    $TempFile = $ConfigPath + ".tmp"
    $JsonOutput = $Base | ConvertTo-Json -Depth 10 -Compress:$false
    $JsonOutput | Out-File -FilePath $TempFile -Encoding UTF8 -Force
    if (Test-Path $ConfigPath) { Remove-Item -Force $ConfigPath -ErrorAction SilentlyContinue }
    Move-Item -Force $TempFile $ConfigPath -ErrorAction Stop
    Write-Log "Claude Code config delivered: $ConfigPath" "INFO"
    return $PreservedCount
}

# ═══════════════════════════════════════════════════════════════════
#                          主 逻 辑
# ═══════════════════════════════════════════════════════════════════

try {
    Write-Log "============================================================"
    Write-Log "  HOST GUARDIAN (Windows v$SCRIPT_VERSION) Platform Engineering"
    Write-Log "============================================================"

    if (-not (Test-Path $CONFIG_FILE)) { throw "Config file not found: $CONFIG_FILE" }
    Write-Log "Config loaded: $CONFIG_FILE" "INFO"

    $CCBin          = Get-YamlValue $CONFIG_FILE "" "windows_bin"
    $DaemonEnabled  = Get-YamlValue $CONFIG_FILE "" "daemon_enabled"
    $UserEmail      = Get-YamlValue $CONFIG_FILE "ai_agent_auth" "user_email"
    $StartupArgs    = Get-YamlValue $CONFIG_FILE "cc_switch" "startup_args"
    $TelemetryRaw   = Get-YamlValue $CONFIG_FILE "claude_code" "telemetry_enabled"
    $ProxyEnvCfg    = Get-YamlValue $CONFIG_FILE "infra_network" "proxy_env_inject"

    if ([string]::IsNullOrEmpty($UserEmail)) { $UserEmail = "tutu@neuro-genesis.local" }
    $Telemetry = ($TelemetryRaw -eq "true")
    $ProxyEnvInject = if ($ProxyEnvCfg -eq "false") { $false } else { $true }

    $ProbePorts = Get-YamlValue $CONFIG_FILE "infra_network" "probe_ports"
    # v16.6.1 FIX (保留): PowerShell YAML 解析器无法解析 YAML 列表格式 (dash-prefixed)，
    #   对 probe_ports 返回空字符串。空字符串不等于 $null，原版 $null 判断不会触发兜底。
    #   修复: 扩展为同时检查空字符串，并在 string→array 转换时过滤空元素防 [int]"" 崩溃
    if ($null -eq $ProbePorts -or [string]::IsNullOrEmpty($ProbePorts)) {
        $ProbePorts = @(15721, 4386, 7890, 10809, 7893, 2334)
    }
    if ($ProbePorts -is [string]) {
        $ProbePorts = @($ProbePorts -split ',' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [int]$_.Trim() })
    }
    $NoProxyExtra = Get-YamlValue $CONFIG_FILE "infra_network" "no_proxy_extra"
    Write-Log "Facts: email=$UserEmail telemetry=$Telemetry inject=$ProxyEnvInject ports=$ProbePorts" "DEBUG"

    # ── Phase 1: 多端口 TCP 活性扫描 ─────────────────────────────
    foreach ($Port in $ProbePorts) {
        if (Test-TcpPort -HostName "127.0.0.1" -Port ([int]$Port) -TimeoutMs 1000) {
            $ActivePort = [int]$Port
            $PortAlive = ($ActivePort -eq 15721)
            Write-Log "Port $Port on 127.0.0.1: TCP reachable" "INFO"
            break
        }
    }

    # ── Phase 2: 幽灵进程检测与冷启动 ─────────────────────────────
    $CCProcess = Get-Process -Name "cc-switch" -ErrorAction SilentlyContinue
    if ($null -ne $CCProcess -and -not $PortAlive) {
        Write-Log "CC-Switch process detected (PID: $($CCProcess.Id)), but port 15721 is dead. Terminating..." "WARN"
        $CCProcess | Stop-Process -Force
        Start-Sleep -Seconds 2
        if ($DaemonEnabled -eq "true" -and -not [string]::IsNullOrEmpty($CCBin) -and (Test-Path $CCBin)) {
            Write-Log "Post-kill cold bootstrap: restarting CC-Switch..." "INFO"
            try {
                $Psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{
                    FileName = $CCBin; Arguments = $StartupArgs
                    WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                    CreateNoWindow = $true; UseShellExecute = $false
                }
                $P = [System.Diagnostics.Process]::Start($Psi)
                Write-Log "CC-Switch restarted (PID: $($P.Id))" "INFO"
                Start-Sleep -Seconds 3
                if (Test-TcpPort -HostName "127.0.0.1" -Port 15721 -TimeoutMs 2000) {
                    $ActivePort = 15721; $PortAlive = $true
                    Write-Log "Post-restart verification: port 15721 ALIVE." "INFO"
                } else { Write-Log "Post-restart verification: port 15721 still dead." "ERROR" }
            } catch { Write-Log "CC-Switch restart failed: $_" "ERROR" }
        }
    }

    if (-not $PortAlive -and $ActivePort -eq 0 -and $DaemonEnabled -eq "true" -and -not [string]::IsNullOrEmpty($CCBin) -and (Test-Path $CCBin)) {
        Write-Log "No active proxy found. Cold bootstrap..." "INFO"
        try {
            $Psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{
                FileName = $CCBin; Arguments = $StartupArgs
                WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                CreateNoWindow = $true; UseShellExecute = $false
            }
            $P = [System.Diagnostics.Process]::Start($Psi)
            Write-Log "CC-Switch hot-plugged (PID: $($P.Id))." "INFO"
            Start-Sleep -Seconds 3
            if (Test-TcpPort -HostName "127.0.0.1" -Port 15721 -TimeoutMs 2000) {
                $ActivePort = 15721; $PortAlive = $true
                Write-Log "Cold bootstrap verified: port 15721 ALIVE." "INFO"
            } else { Write-Log "Cold bootstrap: port 15721 not responding." "WARN" }
        } catch { Write-Log "CC-Switch startup failed: $_" "ERROR" }
    }

    # ── Phase 3: 三层连通性预检 ───────────────────────────────────
    if ($ActivePort -ne 0) {
        $ProxyUrl = "http://127.0.0.1:$ActivePort"
        $DnsOk = Test-DnsResolution "dns.google"
        $DnsStatus = if ($DnsOk) { "OK" } else { "FAIL" }
        $TcpStatus = "OK"

        # v16.6.2: 使用 /v1/messages (CC-Switch 实际实现的 Anthropic 入站端点)
        #   401/403 = 鉴权生效 (CC-Switch 对无效 API key 的正常响应) → VERIFIED
        #   404 = /v1/messages 不应返回 404 (CC-Switch 实现此端点) → DEGRADED
        #   5xx = 服务内部错误 → DEGRADED
        #   连接失败 = 服务可能在启动中 → ALIVE (TCP 可达即足够)
        $HttpResult = Test-HttpEndpoint -Url "http://127.0.0.1:$ActivePort/v1/messages" -TimeoutSec 3
        if ($HttpResult.IsAlive) {
            if ($HttpResult.Degraded) {
                $HttpStatus = "DEGRADED ($($HttpResult.StatusCode), service anomaly)"
                $HealthStatus = "DEGRADED"
            } else {
                $HttpStatus = "VERIFIED ($($HttpResult.StatusCode), auth active)"
                $HealthStatus = "VERIFIED"
            }
        } else {
            $HttpStatus = "NO_RESPONSE"
            # TCP 可达但 HTTP 无响应 — 服务可能在启动中
            $HealthStatus = "ALIVE"
        }
        $HealthDetail = "DNS=$DnsStatus TCP=$TcpStatus HTTP=$HttpStatus"
        Write-Log "Pre-check: $HealthDetail" "INFO"
    } else {
        $HealthStatus = "OFFLINE"
        $HealthDetail = "all ports unreachable on 127.0.0.1"
        Write-Log "Pre-check: $HealthDetail" "WARN"
    }

    # ── Phase 4: 环境变量注入 / 降级 ─────────────────────────────
    if ($ActivePort -ne 0 -and $ProxyEnvInject) {
        $NoProxyList = "localhost,127.0.0.1,::1,.local,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
        if (-not [string]::IsNullOrEmpty($NoProxyExtra)) { $NoProxyList += ",$NoProxyExtra" }
        Set-ProxyEnvironment -ProxyUrl $ProxyUrl -NoProxy $NoProxyList -ApiKey "sk-ant-ccswitch00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005555"
        Write-Log "NO_PROXY isolation: $NoProxyList" "DEBUG"
    } elseif ($ActivePort -ne 0 -and -not $ProxyEnvInject) {
        Write-Log "proxy_env_inject=false: only injecting Claude Code specific vars." "DEBUG"
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $ProxyUrl, "User")
        Set-Item -Path "Env:ANTHROPIC_BASE_URL" -Value $ProxyUrl -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "sk-ant-ccswitch00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005555", "User")
        Set-Item -Path "Env:ANTHROPIC_API_KEY" -Value "sk-ant-ccswitch00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005555" -ErrorAction SilentlyContinue
    } else {
        Write-Log "Upstream OFFLINE. Purging all proxy tokens. Safe Direct Mode." "WARN"
        Clear-ProxyEnvironment
        $NoProxyList = "localhost,127.0.0.1,.local"
    }

    # ── Phase 5: Claude Code 配置合并 ─────────────────────────────
    $EffectiveApiBaseUrl = ""
    if ($ActivePort -ne 0) { $EffectiveApiBaseUrl = "http://127.0.0.1:$ActivePort" }
    $PreservedFieldCount = Merge-ClaudeConfig -ConfigPath $ClaudeConfigFile -UserEmail $UserEmail -Telemetry $Telemetry -ApiBaseUrl $EffectiveApiBaseUrl

    # ── Phase 6: 缓存治理 ────────────────────────────────────────
    $CacheDir = Join-Path $ClaudeConfigDir "cache"
    $StateFile = Join-Path $ClaudeConfigDir "state.json"
    if (Test-Path $CacheDir)  { Remove-Item -Recurse -Force $CacheDir  -ErrorAction SilentlyContinue }
    if (Test-Path $StateFile) { Remove-Item -Force $StateFile -ErrorAction SilentlyContinue }
    Write-Log "Claude Code cache purged for clean state." "DEBUG"

    # ── Phase 7: 健康报告 ────────────────────────────────────────
    $NoProxyCount = ($NoProxyList -split ',' | Where-Object { $_.Trim() -ne '' }).Count
    Write-Log "+------------------------------------------------------------+"
    Write-Log "|                  HEALTH REPORT v$SCRIPT_VERSION                    |"
    Write-Log "+------------------------------------------------------------+"
    Write-Log "|  Active Port     : $(if ($ActivePort -ne 0) { $ActivePort } else { 'NONE (direct)' })"
    Write-Log "|  Proxy URL       : $(if (-not [string]::IsNullOrEmpty($ProxyUrl)) { $ProxyUrl } else { 'N/A (direct mode)' })"
    Write-Log "|  Health Status   : $HealthStatus"
    Write-Log "|  Health Detail   : $HealthDetail"
    Write-Log "|  NO_PROXY Domains: $NoProxyCount"
    Write-Log "|  Env Injection   : $(if ($ProxyEnvInject) { 'FULL (HTTP_PROXY + Claude)' } else { 'CLAUDE-ONLY' })"
    Write-Log "|  Claude Config   : $ClaudeConfigFile"
    Write-Log "|  Fields Preserved: $PreservedFieldCount (lossless)"
    Write-Log "+------------------------------------------------------------+"
    Write-Log "HOST GUARDIAN (Windows v$SCRIPT_VERSION) COMPLETED" "INFO"
    exit 0

} catch {
    Write-Log "Infrastructure unhandled emergency: $_" "FATAL"
    Write-Log "StackTrace: $($_.ScriptStackTrace)" "FATAL"
    exit 1
}