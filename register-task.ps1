# =====================================================================
# NEURO-GENESIS 任务注册脚本 (v16.1 最终硬化版)
# 说明：以管理员身份运行，注册开机 + 登录双触发器自愈任务
# =====================================================================

# -------- 配置变量（请根据实际调整）--------
$SCRIPT_PATH = "E:\OpenClaw_Genesis\scripts\host-guardian.ps1"
$CONFIG_FILE = "E:\OpenClaw_Genesis\global-infra.yaml"
$LOG_ROOT = "E:\OpenClaw_Genesis\logs"
$TASK_NAME = "NeuroGenesisHostGuardian"

# -------- 日志函数（带颜色）--------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp] [$Level] $Message"
    $color = @{
        "INFO"    = "White"
        "SUCCESS" = "Green"
        "WARN"    = "Yellow"
        "ERROR"   = "Red"
    }
    Write-Host $Entry -ForegroundColor $color[$Level] -ErrorAction SilentlyContinue
    # 同时写入文件（若失败则忽略）
    try {
        $logDir = Split-Path "$env:USERPROFILE\.ai-infra\logs\register-task.log" -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -Path "$env:USERPROFILE\.ai-infra\logs\register-task.log" -Value $Entry -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
}

# -------- 管理员权限检查 --------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "请以管理员身份运行此脚本。" "ERROR"
    exit 1
}

# -------- 主流程 --------
try {
    Write-Log "========== 任务注册开始 =========="

    # 1. 防御性前置检查：配置文件、脚本、日志目录是否存在
    if (-not (Test-Path $CONFIG_FILE)) {
        throw "YAML 主配置文件丢失: $CONFIG_FILE"
    }
    $scriptDir = Split-Path $SCRIPT_PATH -Parent
    if (-not (Test-Path $scriptDir)) {
        New-Item -ItemType Directory -Force -Path $scriptDir | Out-Null
        Write-Log "脚本目录已创建: $scriptDir" "INFO"
    }
    if (-not (Test-Path $LOG_ROOT)) {
        New-Item -ItemType Directory -Force -Path $LOG_ROOT | Out-Null
        Write-Log "日志目录已创建: $LOG_ROOT" "INFO"
    }
    Write-Log "全链路前置拓扑依赖路径校验通过" "SUCCESS"

    # 2. 动作定义：锁定工作目录、隐藏窗口、绕过执行策略
    $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SCRIPT_PATH`"" `
        -WorkingDirectory $scriptDir

    # 3. 双触发器：登录后延迟 10 秒 + 开机时启动（无人值守）
    $Trigger1 = New-ScheduledTaskTrigger -AtLogOn
    $Trigger1.Delay = [TimeSpan]::FromSeconds(10)

    $Trigger2 = New-ScheduledTaskTrigger -AtStartup

    # 4. 设置：电池优化、允许唤醒、忽略重叠、5分钟超时
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    # 5. 主体：使用本地 Administrators 组 SID（S-1-5-32-544）最高权限
    $Principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-544" -RunLevel Highest

    # 6. 注册任务（如存在则覆盖）
    Register-ScheduledTask -TaskName $TASK_NAME `
                           -Action $Action `
                           -Trigger @($Trigger1, $Trigger2) `
                           -Settings $Settings `
                           -Principal $Principal `
                           -Description "Neuro-Genesis 自愈监护矩阵：动态拉起 CC-Switch 套利平面，执行无损 JSON 配置合并，防内讧断流。" `
                           -Force

    Write-Log "企业级无感环境自愈任务 '$TASK_NAME' 注册成功！" "SUCCESS"
    Write-Log "双模态冷自举（开机+登录）、5分钟超时、工作目录锁定于 $scriptDir" "INFO"
    exit 0

} catch {
    Write-Log "分布式计划任务注册失败，紧急熔断: $_" "ERROR"
    exit 1
}