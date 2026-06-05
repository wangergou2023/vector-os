#!/bin/bash
# restore.sh — 刷机/重置后一键部署 daima + vector-mcp
# Usage: ./restore.sh <robot-ip>
set -e

ROBOT_IP="${1:?用法: $0 <机器人IP>}"
SSH_KEY="${SSH_KEY:-$HOME/code/github/vector/ssh_root_key.txt}"
WIREOS_DIR="$(cd "$(dirname "$0")" && pwd)"
VECTOR_MCP_DIR="${VECTOR_MCP_DIR:-$HOME/code/github/vector-mcp}"

SSH="ssh -i ${SSH_KEY} root@${ROBOT_IP}"
SCP="scp -i ${SSH_KEY}"

echo "=========================================="
echo "  Daima + vector-mcp 部署"
echo "  Target: ${ROBOT_IP}"
echo "=========================================="

# ── Cross compile ──

echo ""
echo "=== 1. daima-agent (C, ARM) ==="
cd "$WIREOS_DIR/daima-agent"
bash build-arm.sh 2>&1 | tail -2
BIN_SIZE=$(ls -lh build-arm/daima | awk '{print $5}')
echo "    $BIN_SIZE"

echo ""
echo "=== 2. vector-mcp (Go, ARM) ==="
cd "$VECTOR_MCP_DIR/cloud"
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags="-s -w" -o ../build/vic-cloud .
BIN_SIZE=$(ls -lh ../build/vic-cloud | awk '{print $5}')
echo "    $BIN_SIZE"

# ── Deploy ──

echo ""
echo "=== 3. Create directories ==="
$SSH "mkdir -p /data/daima/bin /data/daima/spiffs_data/{config,web,skills,ca,memory,sessions,cache}"
$SSH "mkdir -p /run/vic-cloud"

echo ""
echo "=== 4. Upload binaries ==="
$SSH "systemctl stop daima 2>/dev/null || true"
$SSH "systemctl stop vic-cloud 2>/dev/null || true"
sleep 2
$SSH "mount -o rw,remount /"

$SCP "$WIREOS_DIR/daima-agent/build-arm/daima" "root@${ROBOT_IP}:/data/daima/bin/daima"
$SCP "$VECTOR_MCP_DIR/build/vic-cloud"       "root@${ROBOT_IP}:/anki/bin/vic-cloud"
$SCP "$VECTOR_MCP_DIR/build/vic-cloud"       "root@${ROBOT_IP}:/data/daima/bin/robot-mcp"

$SSH "chmod +x /data/daima/bin/daima /data/daima/bin/robot-mcp /anki/bin/vic-cloud"
$SSH "mount -o remount,ro /"

echo ""
echo "=== 5. Upload resources ==="
rsync -qaz -e "ssh -i ${SSH_KEY}" \
    "$WIREOS_DIR/daima-agent/spiffs_data/" \
    "root@${ROBOT_IP}:/data/daima/spiffs_data/"

echo ""
echo "=== 6. Install daima.service ==="
$SSH "cat > /data/daima/daima.service << 'SVC'
[Unit]
Description=Daima AI Agent
After=vic-cloud.service

[Service]
Type=simple
User=root
WorkingDirectory=/data/daima
Environment=DAIMA_HOME=/data/daima
Environment=DAIMA_MCP_BIN=/data/daima/bin/robot-mcp
ExecStartPre=/bin/mkdir -p /run/vic-cloud
ExecStart=/data/daima/bin/daima
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
# Create persistent symlinks so daima auto-starts on boot (rootfs is read-only, need remount)
$SSH "mount -o rw,remount /
cp /data/daima/daima.service /etc/systemd/system/daima.service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/daima.service /etc/systemd/system/multi-user.target.wants/daima.service
mkdir -p /etc/systemd/system/vic-cloud.service.d
cat > /etc/systemd/system/vic-cloud.service.d/daima.conf << 'EOC'
[Service]
ExecStartPost=-/bin/systemctl start daima
EOC
mount -o remount,ro /
systemctl daemon-reload"

echo ""
echo "=== 7. Start services ==="
$SSH "systemctl start vic-cloud; sleep 5; systemctl start daima; sleep 10"

echo ""
echo "=========================================="
echo "  Deploy complete"
echo "  Gateway: /anki/bin/vic-cloud"
echo "  Daima:   /data/daima/bin/daima"
echo "  Client:  /data/daima/bin/robot-mcp"
echo "  Web UI:  http://${ROBOT_IP}:1234"
echo "  Logs:    journalctl -u daima -f"
echo "=========================================="
