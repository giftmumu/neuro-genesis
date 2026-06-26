#!/usr/bin/env bash
# ==============================================================================
# NEURO-GENESIS Docker 全局网络代理配置脚本 (V3.0 工业级完美版)
# 特性：预检探测、协议自适应、安全回滚、防御性编程。
# ==============================================================================

set -e

# 1. 参数初始化 (支持环境变量覆盖)
PROXY_HOST="host.docker.internal"
PROXY_PORT="${HTTP_PROXY_PORT:-7890}"
# 自动探测协议：优先 HTTP，失败尝试 SOCKS5 (这是扩展性的关键)
PROXY_PROTO="${PROXY_PROTOCOL:-http}" 
PROXY_URL="${PROXY_PROTO}://${PROXY_HOST}:${PROXY_PORT}"

# 2. 增强型豁免列表 (覆盖 IPv4/IPv6 私有网段 + Docker 内部网络)
NO_PROXY_LIST="localhost,127.0.0.1,0.0.0.0,::1,${PROXY_HOST},.local,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"

echo ">>> [Step 1/5] 环境预检与代理探测..."
echo ">>> 目标代理: $PROXY_URL"

# 3. 预检：验证端口可达性 (防御性编程)
# 如果 host.docker.internal 不通，配置了也没用
if ! docker run --rm alpine ping -c 1 $PROXY_HOST > /dev/null 2>&1; then
    echo "❌ 错误：无法解析 $PROXY_HOST。请确保 Docker 正在运行。"
    exit 1
fi

# 4. 预检：验证代理端口连通性 (关键：发现 Clash 未开 Allow LAN 或端口错误)
(echo > /dev/tcp/$PROXY_HOST/$PROXY_PORT) >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
    echo "⚠️  警告：无法连接 $PROXY_HOST:$PROXY_PORT"
    echo "⚠️  请检查：1. Clash 是否开启 'Allow LAN'"
    echo "⚠️          2. Windows 防火墙是否放行 $PROXY_PORT"
    read -p ">>> 是否仍要继续配置？: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ">>> [Step 2/5] 备份原始配置 (安全回滚机制)..."
mkdir -p ~/.docker/backup
[ -f ~/.docker/config.json ] && cp ~/.docker/config.json ~/.docker/backup/config.json.bak
[ -f /etc/docker/daemon.json ] && sudo cp /etc/docker/daemon.json /etc/docker/backup/daemon.json.bak 2>/dev/null || true

echo ">>> [Step 3/5] 注入 Docker 客户端配置..."
mkdir -p ~/.docker
python3 -c "
import json, os
p = os.path.expanduser('~/.docker/config.json')
try: data = json.load(open(p))
except: data = {}
data['proxies'] = data.get('proxies', {})
data['proxies']['default'] = {
    'httpProxy': '$PROXY_URL',
    'httpsProxy': '$PROXY_URL',
    'noProxy': '$NO_PROXY_LIST'
}
json.dump(data, open(p, 'w'), indent=4)
print('✅ 客户端配置完成')
"

echo ">>> [Step 4/5] 注入 Docker 守护进程配置..."
sudo mkdir -p /etc/docker
sudo python3 -c "
import json
p = '/etc/docker/daemon.json'
try: data = json.load(open(p))
except: data = {}
data['proxies'] = {
    'http-proxy': '$PROXY_URL',
    'https-proxy': '$PROXY_URL',
    'no-proxy': '$NO_PROXY_LIST'
}
# 确保 host.docker.internal 可解析
if 'extra-hosts' not in data:
    data['extra-hosts'] = ['host.docker.internal:host-gateway']
json.dump(data, open(p, 'w'), indent=4)
print('✅ 守护进程配置完成')
"
sudo chmod 644 /etc/docker/daemon.json

echo ">>> [Step 5/5] 重启 Docker 引擎..."
if command -v systemctl >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
    sudo systemctl restart docker
else
    echo "⚠️ 未检测到 systemctl，请手动重启 Docker Desktop。"
fi

echo "=========================================="
echo "✅ 工业级配置完成！"
echo ">>> 验证命令:"
echo ">>>   docker run --rm alpine/curl -I https://google.com"
echo ">>> 卸载/回滚命令:"
echo ">>>   cp ~/.docker/backup/config.json.bak ~/.docker/config.json"
echo "=========================================="