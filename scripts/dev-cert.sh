#!/bin/bash
# SPDX-License-Identifier: MIT
# Create once; only an explicit --reset deletes and replaces the identity.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-env.sh
umask 077

MACTOYS_RESET=0
case "${1:-}" in
    '') ;;
    --reset) MACTOYS_RESET=1 ;;
    *) echo "Usage: scripts/dev-cert.sh [--reset]" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: scripts/dev-cert.sh [--reset]" >&2; exit 1; }

if [[ -f "$MACTOYS_SIGNING_KEYCHAIN" && "$MACTOYS_RESET" == 0 ]]; then
    mactoys_unlock_signing_keychain
    if ! security find-identity -p codesigning "$MACTOYS_SIGNING_KEYCHAIN" | grep -Fq "\"$MACTOYS_SIGNING_IDENTITY\""; then
        echo "The existing MacToys keychain has no signing identity; restore it or explicitly run scripts/dev-cert.sh --reset." >&2
        exit 1
    fi
    echo "Reusing $MACTOYS_SIGNING_IDENTITY ($(mactoys_signing_fingerprint))"
    exit 0
fi

mactoys_read_signing_password "请设置新的 MacToys 签名密码（请自行记住，后续构建需输入）"
MACTOYS_NEW_PASSWORD="$MACTOYS_KEYCHAIN_PASSWORD"
unset MACTOYS_KEYCHAIN_PASSWORD
mactoys_read_signing_password "请再次输入新的 MacToys 签名密码"
if [[ "$MACTOYS_NEW_PASSWORD" != "$MACTOYS_KEYCHAIN_PASSWORD" ]]; then
    unset MACTOYS_NEW_PASSWORD MACTOYS_KEYCHAIN_PASSWORD
    echo "两次密码不一致，未修改签名钥匙串。" >&2
    exit 1
fi
unset MACTOYS_KEYCHAIN_PASSWORD

MACTOYS_CERT_WORK="$(mktemp -d)"
MACTOYS_CREATING=0
mactoys_certificate_cleanup() {
    local mactoys_exit_code=$?
    unset MACTOYS_NEW_PASSWORD MACTOYS_CERT_PASSWORD MACTOYS_KEYCHAIN_PASSWORD
    if [[ "$mactoys_exit_code" != 0 && "$MACTOYS_CREATING" == 1 ]]; then
        if [[ -f "$MACTOYS_SIGNING_KEYCHAIN" ]]; then
            security delete-keychain "$MACTOYS_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
            rm -f "$MACTOYS_SIGNING_KEYCHAIN"
        fi
    fi
    rm -rf "$MACTOYS_CERT_WORK"
}
trap mactoys_certificate_cleanup EXIT
cat > "$MACTOYS_CERT_WORK/cert.cnf" <<'CONFIG'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = MacToys Development
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -keyout "$MACTOYS_CERT_WORK/key.pem" -out "$MACTOYS_CERT_WORK/cert.pem" \
    -config "$MACTOYS_CERT_WORK/cert.cnf" 2>/dev/null
export MACTOYS_CERT_PASSWORD="$MACTOYS_NEW_PASSWORD"
openssl pkcs12 -export -inkey "$MACTOYS_CERT_WORK/key.pem" -in "$MACTOYS_CERT_WORK/cert.pem" \
    -out "$MACTOYS_CERT_WORK/identity.p12" -passout env:MACTOYS_CERT_PASSWORD -name "$MACTOYS_SIGNING_IDENTITY"
unset MACTOYS_CERT_PASSWORD

mkdir -p "$(dirname "$MACTOYS_SIGNING_KEYCHAIN")"
if [[ -f "$MACTOYS_SIGNING_KEYCHAIN" ]]; then
    security delete-keychain "$MACTOYS_SIGNING_KEYCHAIN"
    echo "已删除旧的 MacToys 签名钥匙串。"
fi
MACTOYS_CREATING=1
security create-keychain -p "$MACTOYS_NEW_PASSWORD" "$MACTOYS_SIGNING_KEYCHAIN"
security unlock-keychain -p "$MACTOYS_NEW_PASSWORD" "$MACTOYS_SIGNING_KEYCHAIN"
security set-keychain-settings -l -u -t 3600 "$MACTOYS_SIGNING_KEYCHAIN"
security import "$MACTOYS_CERT_WORK/identity.p12" -k "$MACTOYS_SIGNING_KEYCHAIN" \
    -P "$MACTOYS_NEW_PASSWORD" -x -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$MACTOYS_NEW_PASSWORD" "$MACTOYS_SIGNING_KEYCHAIN" >/dev/null
unset MACTOYS_NEW_PASSWORD
chmod 600 "$MACTOYS_SIGNING_KEYCHAIN"
MACTOYS_FINGERPRINT="$(mactoys_signing_fingerprint)"
[[ "$MACTOYS_FINGERPRINT" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "Invalid signing certificate fingerprint" >&2; exit 1; }
MACTOYS_CREATING=0
echo "Created $MACTOYS_SIGNING_IDENTITY ($MACTOYS_FINGERPRINT)"
echo "密码未保存到文件。后续运行 scripts/build-app.sh 时输入此密码即可。"
