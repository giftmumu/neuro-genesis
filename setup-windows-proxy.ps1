# =====================================================================
# NEURO-GENESIS 网络基础设施一键配置脚本 (Windows + Docker Desktop)
# 作用: 自动配置防火墙、注入 Docker 全局代理、打通 host.docker.internal
# =====================================================================
 $ErrorActionPreference = "Stop"

Write-Host ">>> [Step 1/3] 正在配置 Windows 防火墙规则..." -ForegroundColor Cyan

# 1. 防火墙规则 (幂等性设计：先删后加)
 $RuleName = "Docker_to_Proxy_Bridge"
if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -Name $RuleName
}

# 放行常用代理端口 (HTTP 7890 / SOCKS5 7891)
New-NetFirewallRule -DisplayName "Docker to Windows Proxy" `
    -Name $RuleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 7890, 7891 `
    -Profile Private,Public `
    -Description "允许 Docker 容器通过 host.docker.internal 访问 Windows 代理"

Write-Host "✅ 防火墙规则已更新" -ForegroundColor Green

# 2. Docker Desktop 全局配置注入
Write-Host ">>> [Step 2/3] 正在注入 Docker Desktop 全局代理配置..." -ForegroundColor Cyan
 $SettingsPath = "$env:USERPROFILE\.docker\settings.json"

if (Test-Path $SettingsPath) {
    $Settings = Get-Content $SettingsPath | ConvertFrom-Json
} else {
    $Settings = @{}
}

# 动态构建配置结构
if (-not $Settings.proxies) { $Settings | Add-Member -NotePropertyName "proxies" -NotePropertyValue @{} }
if (-not $Settings.proxies.default) { $Settings.proxies | Add-Member -NotePropertyName "default" -NotePropertyValue @{} }

# 核心配置：使用 host.docker.internal 动态指向宿主机
 $Settings.proxies.default.httpProxy  = "http://host.docker.internal:7890"
 $Settings.proxies.default.httpsProxy = "http://host.docker.internal:7890"

# 核心配置：优雅降级 - 豁免所有内部服务名和私有网段
 $Settings.proxies.default.noProxy = "localhost,127.0.0.1,0.0.0.0,::1,openclaw,emotion-engine,visual-server,ollama,prometheus,grafana,.local,.internal,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"

# 写回文件
 $Settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsPath -Encoding UTF8

Write-Host "✅ Docker 全局配置已写入: $SettingsPath" -ForegroundColor Green

# 3. 后续指引
Write-Host "`n>>> [Step 3/3] 配置完成！请执行最后两步手动操作:" -ForegroundColor Yellow
Write-Host "1. 打开 Clash/FlClash -> 设置 -> 开启【允许局域网连接】" -ForegroundColor White
Write-Host "2. 重启 Docker Desktop (右键托盘图标 -> Restart)" -ForegroundColor White
Write-Host "3. 重启完成后，在 WSL2 中执行 'docker compose up -d'" -ForegroundColor White