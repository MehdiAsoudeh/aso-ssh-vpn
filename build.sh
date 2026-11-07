#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ASO VPN"
VERSION="${ASO_VPN_VERSION:-2.0.0}"
MIN_MACOS="12.0"
SDK="$(xcrun --show-sdk-path)"
OUT_DIR="${ROOT}/dist"
APP_DIR="${OUT_DIR}/${APP_NAME}.app"
ICON_ICNS="${ROOT}/resources/AppIcon.icns"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
fail() { echo "error: $*" >&2; exit 1; }
need clang
need lipo
need xcrun
[[ -f "${ROOT}/vpn.sh" ]] || fail "vpn.sh missing"
bash -n "${ROOT}/vpn.sh" || fail "vpn.sh syntax error"

echo "==> Running session policy tests..."
clang -fobjc-arc -framework Foundation \
  -I"${ROOT}" \
  "${ROOT}/VPNSessionPolicy.m" \
  "${ROOT}/tests/test_session_policy.m" \
  -o "${ROOT}/.test-session-policy"
"${ROOT}/.test-session-policy"
rm -f "${ROOT}/.test-session-policy"

rm -rf "${OUT_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
SRCS=("${ROOT}/VPNApp.m" "${ROOT}/VPNSessionPolicy.m")
# Always ship a universal binary so one build runs on Intel and Apple Silicon (M1–M4).
echo "==> Compiling arm64 (Apple Silicon)..."
clang -O2 -fobjc-arc \
  -target "arm64-apple-macos${MIN_MACOS}" \
  -isysroot "${SDK}" \
  -framework Cocoa -framework Foundation \
  -I"${ROOT}" \
  "${SRCS[@]}" \
  -o "${ROOT}/.build-arm64"
echo "==> Compiling x86_64 (Intel)..."
clang -O2 -fobjc-arc \
  -target "x86_64-apple-macos${MIN_MACOS}" \
  -isysroot "${SDK}" \
  -framework Cocoa -framework Foundation \
  -I"${ROOT}" \
  "${SRCS[@]}" \
  -o "${ROOT}/.build-x86_64"
echo "==> Creating universal binary..."
lipo -create "${ROOT}/.build-arm64" "${ROOT}/.build-x86_64" -output "${APP_DIR}/Contents/MacOS/${APP_NAME}"
ARCHS="$(lipo -archs "${APP_DIR}/Contents/MacOS/${APP_NAME}")"
echo " ${ARCHS} " | grep -q " arm64 " || { echo "error: universal binary missing arm64 (got: ${ARCHS})"; exit 1; }
echo " ${ARCHS} " | grep -q " x86_64 " || { echo "error: universal binary missing x86_64 (got: ${ARCHS})"; exit 1; }
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
# Ship vpn.sh BEFORE any optional steps — a failed build must never leave an app without it.
cp "${ROOT}/vpn.sh" "${APP_DIR}/Contents/Resources/vpn.sh"
chmod +x "${APP_DIR}/Contents/Resources/vpn.sh"
bash -n "${APP_DIR}/Contents/Resources/vpn.sh" || fail "bundled vpn.sh is invalid"
[[ -x "${APP_DIR}/Contents/Resources/vpn.sh" ]] || fail "bundled vpn.sh not executable"
if [[ -f "${ICON_ICNS}" ]]; then
  cp "${ICON_ICNS}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ASO VPN</string>
  <key>CFBundleDisplayName</key><string>ASO VPN</string>
  <key>CFBundleExecutable</key><string>ASO VPN</string>
  <key>CFBundleIdentifier</key><string>com.aso.ssh-vpn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "${APP_DIR}" 2>/dev/null || true
rm -f "${ROOT}/.build-arm64" "${ROOT}/.build-x86_64"
echo "==> Verifying bundle..."
[[ -x "${APP_DIR}/Contents/MacOS/${APP_NAME}" ]] || fail "binary missing"
[[ -f "${APP_DIR}/Contents/Resources/vpn.sh" ]] || fail "Resources/vpn.sh missing — app would permission-loop"
[[ -f "${APP_DIR}/Contents/Info.plist" ]] || fail "Info.plist missing"
echo "==> Built: ${APP_DIR} (v${VERSION})"
file "${APP_DIR}/Contents/MacOS/${APP_NAME}"
ls -la "${APP_DIR}/Contents/Resources/"
echo
echo "Run:"
echo "  open \"${APP_DIR}\""
echo
echo "Config is saved to:"
echo "  ~/Library/Application Support/ASO VPN/profiles.json"
