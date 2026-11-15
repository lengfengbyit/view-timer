#!/usr/bin/env bash
# 由 assets/icon.svg 重新生成 assets/AppIcon.icns（16–1024 全套尺寸）
#
# 依赖 librsvg： brew install librsvg   （提供 rsvg-convert）
# 只改图标的话，跑完这个再 ./scripts/install.sh 即可。
#
# 注意：SVG 里不要用 filter（feDropShadow 等在 librsvg 下会把整块渲染坏），
# 用 stop-opacity 的渐变做光影是正常的。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/assets/icon.svg"
ICNS="$ROOT/assets/AppIcon.icns"
WORK="$(mktemp -d)/AppIcon.iconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "缺少 rsvg-convert，请先执行： brew install librsvg" >&2
  exit 1
fi
[ -f "$SVG" ] || { echo "找不到 $SVG" >&2; exit 1; }

echo "==> 栅格化 1024×1024"
MASTER="$(dirname "$WORK")/master.png"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$MASTER"

echo "==> 生成 iconset"
mkdir -p "$WORK"
for s in 16 32 64 128 256 512 1024; do
  sips -z "$s" "$s" "$MASTER" --out "$(dirname "$WORK")/_$s.png" >/dev/null 2>&1
done
D="$(dirname "$WORK")"
cp "$D/_16.png"   "$WORK/icon_16x16.png"
cp "$D/_32.png"   "$WORK/icon_16x16@2x.png"
cp "$D/_32.png"   "$WORK/icon_32x32.png"
cp "$D/_64.png"   "$WORK/icon_32x32@2x.png"
cp "$D/_128.png"  "$WORK/icon_128x128.png"
cp "$D/_256.png"  "$WORK/icon_128x128@2x.png"
cp "$D/_256.png"  "$WORK/icon_256x256.png"
cp "$D/_512.png"  "$WORK/icon_256x256@2x.png"
cp "$D/_512.png"  "$WORK/icon_512x512.png"
cp "$D/_1024.png" "$WORK/icon_512x512@2x.png"

echo "==> 打包 icns"
iconutil -c icns "$WORK" -o "$ICNS"
echo "完成：${ICNS}（$(du -h "$ICNS" | cut -f1 | tr -d ' ')）"
