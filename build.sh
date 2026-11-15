#!/usr/bin/env bash
# view-timer 一键构建（swiftc 路径，无需 Xcode 工程）
# 产物：build/view-timer.app
#
# 已在 macOS 15.8.3 / x86_64 / Command Line Tools (Swift 6.1.2) 实测通过。
# 若提示找不到 SDK：xcode-select --install，或 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

set -euo pipefail

APP_NAME="view-timer"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> 检查工具链"
if ! command -v xcrun >/dev/null 2>&1; then
  echo "未找到 xcrun。请先执行：xcode-select --install" >&2
  exit 1
fi
SDK="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || true)"
SWIFTC="$(xcrun -f swiftc 2>/dev/null || true)"
if [ -z "$SDK" ] || [ -z "$SWIFTC" ]; then
  echo "无法定位 macOS SDK 或 swiftc，请检查 Xcode Command Line Tools。" >&2
  exit 1
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx12.0"
echo "    SDK    : $SDK"
echo "    swiftc : $SWIFTC"
echo "    target : $TARGET"

echo "==> 组装 .app 目录"
rm -rf "$BUILD"
mkdir -p "$MACOS" "$RES"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

# 版本号以 Sources/AppConfig.swift 为唯一来源。
# 以前 Info.plist 里是手写的静态值，改了 Swift 常量却忘了同步，
# 结果系统里显示 1.1.0、App 日志里写 1.2.0 —— 这里让构建时自动覆盖。
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "${ROOT}/Sources/AppConfig.swift")"
BUILD_NUMBER="$(sed -n 's/.*static let buildNumber = "\([^"]*\)".*/\1/p' "${ROOT}/Sources/AppConfig.swift")"
if [ -n "${VERSION}" ] && [ -n "${BUILD_NUMBER}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$CONTENTS/Info.plist"
  echo "    版本：${VERSION} (${BUILD_NUMBER})"
fi

echo "==> 图标"
ICON="$ROOT/assets/AppIcon.icns"
# 仓库只保留 icon.svg 源文件；克隆后首次构建时自动补齐二进制图标。
# 生成失败（比如没装 rsvg-convert）不阻断构建，只是 App 没有图标。
if [ ! -f "$ICON" ] && [ -f "$ROOT/scripts/make-icon.sh" ]; then
  echo "    未找到 AppIcon.icns，尝试从 icon.svg 生成"
  if "$ROOT/scripts/make-icon.sh" >/dev/null 2>&1; then
    echo "    已生成 AppIcon.icns"
  else
    echo "    生成失败（需要 rsvg-convert: brew install librsvg），本次构建不带图标"
  fi
fi
if [ -f "$ICON" ]; then
  cp "$ICON" "$RES/AppIcon.icns"
  echo "    AppIcon.icns（含 16–1024，$(du -h "$ICON" | cut -f1 | tr -d ' ')）"
else
  echo "    [警告] 缺少 assets/AppIcon.icns，App 会显示成白板"
  echo "           重建图标：./scripts/make-icon.sh"
fi

echo "==> 编译 Sources/*.swift"
SOURCES=("$ROOT"/Sources/*.swift)
# 注意：入口是 Sources/main.swift（顶层代码），因此不能加 -parse-as-library
"$SWIFTC" \
  -target "$TARGET" \
  -sdk "$SDK" \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework CoreAudio \
  -framework Foundation \
  -o "$MACOS/$APP_NAME" \
  "${SOURCES[@]}"

echo "==> 签名"
# 签名方式，默认 auto（有稳定证书身份就用它，否则退回 ad-hoc）：
#
#   cert（推荐，scripts/setup-signing.sh 生成后自动启用）
#     用自签证书签名，指定要求变成 identifier + 证书根，**重新编译不掉授权**。
#     前提：证书根必须被**系统域**信任（/Library/Keychains/System.keychain），
#     否则 tccd 做签名链验证会失败，表现是「App 能拖进辅助功能列表但勾选不生效」。
#
#   ad-hoc（没有证书时的兜底）
#     指定要求是二进制 cdhash，不需要任何证书链参与，一定能加进辅助功能；
#     代价：重新编译后 cdhash 变化，要重新勾选一次。
#
#   SIGN=adhoc ./build.sh   # 强制 ad-hoc
#   SIGN=cert  ./build.sh   # 强制证书
SIGN_MODE="${SIGN:-auto}"
if [ "$SIGN_MODE" = "auto" ]; then
  if security find-identity -v -p codesigning "$HOME/Library/Keychains/vtsign.keychain-db" 2>/dev/null \
       | grep -q "view-timer Dev"; then
    SIGN_MODE="cert"
  else
    SIGN_MODE="adhoc"
  fi
fi
if [ "$SIGN_MODE" = "cert" ]; then
  SIGN_ID="view-timer Dev"
  SIGN_KC="$HOME/Library/Keychains/vtsign.keychain-db"
  if security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    # 钥匙串密码绝不入库：环境变量优先，其次本机私有文件（权限 600）
    KC_PASS="${VT_SIGNING_KC_PASS:-}"
    if [ -z "$KC_PASS" ] && [ -f "$HOME/.viewtimer-sign/keychain.pass" ]; then
      KC_PASS="$(tr -d '\r\n' < "$HOME/.viewtimer-sign/keychain.pass")"
    fi
    if [ -n "$KC_PASS" ]; then
      security unlock-keychain -p "$KC_PASS" "$SIGN_KC" >/dev/null 2>&1 || true
    else
      echo "    [警告] 未配置签名钥匙串密码：设置 VT_SIGNING_KC_PASS，或运行 ./scripts/setup-signing.sh"
    fi
    if codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
      echo "    已签名（${SIGN_ID}）"
      echo "    [提醒] 若辅助功能勾选不生效，说明证书根未被系统域信任，执行："
      echo "           sudo security add-trusted-cert -d -r trustRoot -p codeSign \\"
      echo "             -k /Library/Keychains/System.keychain $HOME/.viewtimer-sign/cert.pem"
    else
      echo "    [警告] 证书签名失败，退回 ad-hoc"
      codesign --force --deep --sign - "$APP"
    fi
  else
    echo "    [警告] 未找到 ${SIGN_ID}，退回 ad-hoc；可先跑 ./scripts/setup-signing.sh"
    codesign --force --deep --sign - "$APP"
  fi
else
  codesign --force --deep --sign - "$APP"
  echo "    已签名（ad-hoc，可直接加入「辅助功能」）"
fi

echo ""
echo "构建完成：$APP"
echo "启动： open \"$APP\""
echo "装到应用程序并重设授权： ./scripts/install.sh"
echo ""
echo "首次运行请在 系统设置 → 隐私与安全性 → 辅助功能 里点「+」加入 view-timer。"
echo "重新编译后若发键失效：把列表里的 view-timer 点「−」删掉再加一次（或用 ./scripts/install.sh）。"
