#!/usr/bin/env bash
# 构建 → 装进 /Applications → 清掉旧的「辅助功能」授权记录 → 重新注册 → 启动
#
# 为什么需要这个脚本：
#   App 在别处编译、又被手动拖到 /Applications，同一个 bundle id 会留下多条
#   LaunchServices 注册记录和一条「指向旧二进制」的 TCC 授权记录。
#   这时在系统设置里点「+」加 App，系统认的是旧记录，表现为「添加了但勾选不生效」。
#   本脚本在最终路径上重新签名，并重置该 bundle id 的辅助功能记录，让系统重新登记。
#
# 用法：
#   ./scripts/install.sh           # 默认 ad-hoc 签名（最稳，能加进辅助功能）
#   SIGN=cert ./scripts/install.sh # 用自签证书签名（需证书根已被系统域信任）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="view-timer"
BUNDLE_ID="com.viewtimer.app"
DEST="/Applications/$APP_NAME.app"
BUILT="$ROOT/build/$APP_NAME.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> 退出正在运行的实例"
pkill -f "$DEST/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "$BUILT/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.6

echo "==> 构建"
"$ROOT/build.sh"

echo "==> 安装到 $DEST"
BK="$HOME/.viewtimer-backup/$(date +%Y%m%d-%H%M%S)"
if [ -d "$DEST" ]; then
  mkdir -p "$BK"
  mv "$DEST" "$BK/"
  echo "    旧版本已备份：$BK/$APP_NAME.app"
fi
ditto "$BUILT" "$DEST"

echo "==> 去掉隔离属性"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> 在最终路径上重新签名"
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
  codesign --force --deep --sign "$SIGN_ID" "$DEST"
  codesign --verify --strict --verbose=2 "$DEST"
  echo "    证书签名（重新编译不会掉「辅助功能」授权）"
else
  codesign --force --deep --sign - "$DEST"
  codesign --verify --strict --verbose=2 "$DEST"
  echo "    ad-hoc 签名（重新编译后需要重新授权）"
fi

# 只有 ad-hoc 才需要清授权：它的指定要求就是 cdhash，重编译必然失效。
# 证书签名下指定要求是证书根，与二进制无关 —— 这时候 reset 反而是自断授权。
if [ "$SIGN_MODE" = "adhoc" ]; then
  echo "==> 重置该 App 的「辅助功能」授权记录"
  tccutil reset Accessibility "$BUNDLE_ID" 2>&1 | tail -1 || true
fi

echo "==> 注销重复的 LaunchServices 注册并重新注册"
# 同一 bundle id 的其它副本（废纸篓、旧构建目录）会导致系统认错 App
for stale in "$HOME/.Trash/$APP_NAME.app" "$BUILT"; do
  [ -d "$stale" ] && "$LSREG" -u "$stale" 2>/dev/null || true
done
"$LSREG" -f "$DEST" 2>/dev/null || true

echo "==> 启动"
open "$DEST"

cat <<'TIP'

────────────────────────────────────────────────
安装完成。

若使用证书签名（默认，前提是跑过 ./scripts/setup-signing.sh 并把证书根
装进系统域）：重新编译不会掉授权，**不需要再动辅助功能列表**。

若退回 ad-hoc 签名：每次重新编译后要去
系统设置 → 隐私与安全性 → 辅助功能，把 view-timer 用「−」删掉再「+」加回来。
────────────────────────────────────────────────
TIP
