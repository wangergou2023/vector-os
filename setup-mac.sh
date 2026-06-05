#!/bin/bash
# setup-mac.sh — 新 Mac 一键安装 daima-agent + vector-mcp 开发环境
# Prerequisite: Xcode Command Line Tools (xcode-select --install)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  WireOS 开发环境安装 (macOS arm64)"
echo "=========================================="

ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
    echo "WARNING: Current arch is $ARCH. vicos-sdk only provides arm64-macos."
    read -p "Continue? (y/N): " yn
    [[ "$yn" != "y" && "$yn" != "Y" ]] && exit 0
fi

# ── Homebrew ──
if ! command -v brew &>/dev/null; then
    echo ""
    echo "=== 1. Install Homebrew ==="
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ "$ARCH" == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    echo "Homebrew: OK"
fi

# ── Tools ──
echo "=== 2. Install base tools ==="
brew install cmake go git wget 2>&1 | tail -1
echo "  cmake $(cmake --version | head -1 | awk '{print $NF}')"
echo "  go $(go version | awk '{print $3}')"

# ── vicos-sdk ──
SDK_VER="5.3.0-r07"
SDK_DIR="$HOME/.anki/vicos-sdk/dist/$SDK_VER"

echo ""
echo "=== 3. Install vicos-sdk (ARM cross-compile toolchain) ==="
if [[ -f "$SDK_DIR/prebuilt/bin/arm-oe-linux-gnueabi-clang" ]]; then
    echo "  vicos-sdk: OK ($SDK_DIR)"
else
    echo "  Downloading (~655MB, ~5-10 min)..."
    mkdir -p "$SDK_DIR"
    cd "$SDK_DIR"
    curl -sL "https://github.com/os-vector/wire-os-externals/releases/download/$SDK_VER/vicos-sdk_${SDK_VER}_arm64-macos.tar.gz" -o vicos-sdk.tar.gz
    echo "  Extracting..."
    tar xzf vicos-sdk.tar.gz
    rm vicos-sdk.tar.gz
    echo "  vicos-sdk: installed"
fi

# ── GCC (linker dependency) ──
if ! ls /opt/homebrew/opt/gcc/lib/gcc/current/libstdc++.6.dylib &>/dev/null; then
    echo ""
    echo "=== 4. Install GCC (vicos-sdk linker dependency) ==="
    brew install gcc 2>&1 | tail -1
fi

# ── Verify ──
echo ""
echo "=== 5. Verify ==="

CLANG="$SDK_DIR/prebuilt/bin/arm-oe-linux-gnueabi-clang"

cat > /tmp/test-arm.c << 'EOF'
#include <stdio.h>
int main() { printf("hello ARM\n"); return 0; }
EOF

if "$CLANG" --target=arm-oe-linux-gnueabi --sysroot="$SDK_DIR/sysroot" -o /tmp/test-arm /tmp/test-arm.c 2>/dev/null; then
    echo "  C -> ARM cross-compile:    OK"
    rm -f /tmp/test-arm /tmp/test-arm.c
else
    echo "  C -> ARM cross-compile:    FAILED"
fi

cat > /tmp/test-go.go << 'EOF'
package main
import "fmt"
func main() { fmt.Println("hello") }
EOF

if GOOS=linux GOARCH=arm GOARM=7 go build -o /tmp/test-go /tmp/test-go.go 2>/dev/null; then
    echo "  Go -> ARM cross-compile:   OK"
    rm -f /tmp/test-go /tmp/test-go.go
else
    echo "  Go -> ARM cross-compile:   FAILED"
fi

# ── Build daima-agent ──
echo ""
echo "=== 6. Build daima-agent ==="
if [[ -d "$SCRIPT_DIR/daima-agent" ]]; then
    cd "$SCRIPT_DIR/daima-agent"
    bash build-arm.sh 2>&1 | tail -2
    echo "  Output: $(ls -lh build-arm/daima 2>/dev/null | awk '{print $5}' || echo 'build failed')"
fi

# ── Done ──
echo ""
echo "=========================================="
echo "  Setup complete"
echo "  Build daima:  cd daima-agent && ./build-arm.sh"
echo "  Build mcp:    cd ~/code/github/vector-mcp/cloud"
echo "                GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build ..."
echo "  Deploy:       ./restore.sh <robot-ip>"
echo "=========================================="

