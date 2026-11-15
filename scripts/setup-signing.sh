#!/usr/bin/env bash
# 创建 view-timer 的稳定代码签名身份（推荐，做一次即可）。
#
# 做完本脚本后还需要一步「装进系统域」——会要一次管理员密码：
#
#        ./scripts/setup-signing.sh
#        sudo security add-trusted-cert -d -r trustRoot -p codeSign \
#          -k /Library/Keychains/System.keychain ~/.viewtimer-sign/cert.pem
#
# 之后 `./scripts/install.sh` 会自动优先用这个身份签名，重新编译不再掉授权。
#
# 为什么必须装进**系统域**信任：
#   自签证书签名后，TCC 的指定要求变成 identifier + 证书根，tccd 会做签名链
#   验证。若证书根只在用户域（或只挂在某个独立钥匙串里），链验证失败，表现
#   就是「App 能拖进辅助功能列表，但勾选不生效 / 条目自己消失」。
#   判定方法：codesign --verify -R='anchor trusted' /Applications/view-timer.app
#   退出码 0 才算真的信任成功。
#
# 另一个踩过的坑：证书若声明 CA:FALSE，`add-trusted-cert -r trustRoot` 会
# 静默不生效（security dump-trust-settings 里显示 "trust settings: 0"），
# 而且系统钥匙串里能看到证书却验不过链。本脚本生成的证书已改为
# CA:TRUE + keyCertSign，若手上是旧证书请加 --force 重建。
#
# 用法：
#   ./scripts/setup-signing.sh          # 幂等，已存在则跳过
#   ./scripts/setup-signing.sh --force  # 删掉重建（会让已有授权失效一次）
#   VT_SIGNING_KC_PASS=xxx ./scripts/setup-signing.sh  # 指定钥匙串密码
#
# 钥匙串密码只存在本机：环境变量 VT_SIGNING_KC_PASS 优先，否则读/生成
# ~/.viewtimer-sign/keychain.pass（权限 600）。仓库里不含任何明文口令。

set -euo pipefail

IDENTITY="view-timer Dev"
KEYCHAIN="$HOME/Library/Keychains/vtsign.keychain-db"
WORK="$HOME/.viewtimer-sign"
PASS_FILE="$WORK/keychain.pass"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "$FORCE" = "1" ]; then
  echo "==> 清理旧身份"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> 稳定签名身份已就绪：$IDENTITY"
  exit 0
fi

echo "==> 生成自签名代码签名证书"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=view-timer Dev
O=view-timer
[ext]
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:true
CNF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem -days 3650 -config cert.cnf >/dev/null 2>&1
fi

# 读取（或首次生成）本机钥匙串密码；环境变量优先，其次是私有文件，最后随机生成。
KC_PASS="${VT_SIGNING_KC_PASS:-}"
if [ -z "$KC_PASS" ] && [ -f "$PASS_FILE" ]; then
  KC_PASS="$(tr -d '\r\n' < "$PASS_FILE")"
fi
if [ -z "$KC_PASS" ]; then
  KC_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
  printf '%s\n' "$KC_PASS" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "==> 已生成本机签名钥匙串密码：$PASS_FILE（权限 600，不入库）"
fi

# macOS 的 security 不认 OpenSSL 3 默认的 PBES2，必须退回 SHA1/3DES
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout "pass:$KC_PASS" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "==> 导入独立钥匙串（不动 login 钥匙串）"
security create-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import id.p12 -k "$KEYCHAIN" -P "$KC_PASS" -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> 标记为受信任的签名根（用户域，尽力而为）"
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" cert.pem >/dev/null 2>&1 || true

# 用户域的信任对 tccd 的签名链验证不保证有效，必须确认/升级到系统域
if security dump-trust-settings 2>/dev/null | grep -A1 "$IDENTITY" | grep -q "Number of trust settings : 0"; then
  echo ""
  echo "[重要] 用户域信任设置未生效。要让「辅助功能」能识别这个签名的 App，"
  echo "       需要把证书根装进系统域（会要一次管理员密码）："
  echo ""
  echo "       sudo security add-trusted-cert -d -r trustRoot -p codeSign \\"
  echo "         -k /Library/Keychains/System.keychain $WORK/cert.pem"
  echo ""
  echo "       然后： SIGN=cert ./scripts/install.sh"
  echo "       如果仍然加不进辅助功能，直接放弃证书方案，用默认的 ad-hoc：./scripts/install.sh"
  echo ""
fi

echo "==> 加入钥匙串搜索列表"
EXISTING=$(security list-keychains -d user | tr -d ' "')
if ! echo "$EXISTING" | grep -q "vtsign.keychain-db"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$IDENTITY"; then
  echo "完成：$IDENTITY 可用于签名"
else
  echo "失败：未能创建可用的签名身份" >&2
  exit 1
fi
