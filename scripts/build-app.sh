#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
source scripts/signing-env.sh
SIGNING_ARGS=()
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
    mactoys_unlock_signing_keychain
    SIGNING_ARGS=(--sign "$MACTOYS_SIGNING_IDENTITY" --keychain "$MACTOYS_SIGNING_KEYCHAIN")
    SIGNING_FINGERPRINT="$(mactoys_signing_fingerprint)"
    [[ "$SIGNING_FINGERPRINT" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "Invalid signing certificate fingerprint" >&2; exit 1; }
    # Pin the certificate and application ID, never the per-build executable hash.
    SIGNING_ARGS+=(--requirements "=designated => identifier \"app.mactoys.MacToys\" and certificate leaf = H\"$SIGNING_FINGERPRINT\"")
elif [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing is disabled: it breaks persistent macOS permission identity." >&2
    exit 1
else
    SIGNING_ARGS=(--sign "$CODE_SIGN_IDENTITY")
    if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then SIGNING_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN"); fi
fi
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_ARGS=(-c "$CONFIGURATION")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$PWD/build/MacToys.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacToys" "$APP/Contents/MacOS/MacToys"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
for lang in en zh-Hans; do
    rm -rf "$APP/Contents/Resources/$lang.lproj"
    cp -R "Resources/$lang.lproj" "$APP/Contents/Resources/"
done
codesign --force "${SIGNING_ARGS[@]}" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
if [[ "$REQUIREMENT" == *"cdhash H"* || "$REQUIREMENT" != *"designated =>"* ]]; then
    echo "Signing must have a stable certificate requirement, not a build-specific hash." >&2
    exit 1
fi
codesign -d -r- "$APP"
echo "Built $APP"
scripts/install-app.sh
