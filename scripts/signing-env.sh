#!/bin/bash
# Local signing material stays outside the repository and global trust settings.
MACTOYS_SIGNING_IDENTITY="MacToys Development"
MACTOYS_SIGNING_KEYCHAIN="$HOME/Library/Keychains/mactoys-dev.keychain-db"

# Keep the password in process memory only; never print it or write it to disk.
mactoys_read_signing_password() {
    local mactoys_prompt="$1"
    if [[ -t 0 ]]; then
        printf '%s: ' "$mactoys_prompt" >&2
        IFS= read -r -s MACTOYS_KEYCHAIN_PASSWORD || return 1
        printf '\n' >&2
    else
        MACTOYS_KEYCHAIN_PASSWORD="$(osascript - "$mactoys_prompt" <<'APPLESCRIPT'
on run argv
    set passwordDialog to display dialog (item 1 of argv) with title "MacToys 应用签名" default answer "" with hidden answer buttons {"取消", "确定"} default button "确定" cancel button "取消"
    return text returned of passwordDialog
end run
APPLESCRIPT
        )" || return 1
    fi
    if [[ -z "$MACTOYS_KEYCHAIN_PASSWORD" ]]; then
        echo "签名密码不能为空。" >&2
        return 1
    fi
}

mactoys_unlock_signing_keychain() {
    if [[ ! -f "$MACTOYS_SIGNING_KEYCHAIN" ]]; then
        echo "缺少签名钥匙串，请先运行 scripts/dev-cert.sh。" >&2
        return 1
    fi
    mactoys_read_signing_password "请输入 MacToys 签名钥匙串密码" || return 1
    local mactoys_unlock_result=0
    security unlock-keychain -p "$MACTOYS_KEYCHAIN_PASSWORD" "$MACTOYS_SIGNING_KEYCHAIN" || mactoys_unlock_result=$?
    unset MACTOYS_KEYCHAIN_PASSWORD
    if [[ "$mactoys_unlock_result" != 0 ]]; then
        echo "钥匙串解锁失败，请检查签名密码后重试。" >&2
    fi
    return "$mactoys_unlock_result"
}

mactoys_signing_fingerprint() {
    security find-certificate -c "$MACTOYS_SIGNING_IDENTITY" -p "$MACTOYS_SIGNING_KEYCHAIN" |
        openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
}
