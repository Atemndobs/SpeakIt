#!/usr/bin/env bash
# Build and install SpeakIt.app into ~/Applications, with the macOS Services
# entry registered. Run from anywhere — script resolves repo root itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpeakIt"
DEST="${HOME}/Applications"
APP_PATH="${DEST}/${APP_NAME}.app"

cd "${REPO_ROOT}"

echo "› Building universal release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

# Multi-arch builds land in .build/apple/Products/Release/ instead of
# .build/release/. Fall back to single-arch path if needed.
BIN_PATH=".build/apple/Products/Release/${APP_NAME}"
[ -f "${BIN_PATH}" ] || BIN_PATH=".build/release/${APP_NAME}"

echo "› Assembling ${APP_PATH}"
mkdir -p "${DEST}"
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"
cp "${BIN_PATH}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
cp "scripts/Info.plist" "${APP_PATH}/Contents/Info.plist"
printf "APPL????" > "${APP_PATH}/Contents/PkgInfo"

# Copy SwiftPM resource bundles (e.g. KeyboardShortcuts_KeyboardShortcuts.bundle)
# next to the binary so Bundle.module can resolve at runtime. Without these
# the app crashes (SIGILL in Bundle.module) on first access to a resource —
# notably the KeyboardShortcuts recorder when the menu bar opens.
BUILD_DIR="$(dirname "${BIN_PATH}")"
shopt -s nullglob 2>/dev/null || true
for bundle in "${BUILD_DIR}"/*.bundle; do
    [ -e "${bundle}" ] || continue
    echo "› Copying resource bundle: $(basename "${bundle}")"
    cp -R "${bundle}" "${APP_PATH}/Contents/Resources/"
done

# Optionally sync app version into Info.plist (CFBundleShortVersionString),
# so the bundle reports the release tag rather than a stale hardcoded value.
# Pass SPEAKIT_VERSION=0.2.2 to override.
if [ -n "${SPEAKIT_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SPEAKIT_VERSION}" "${APP_PATH}/Contents/Info.plist" || true
fi

IDENTITY="SpeakIt Self-Signed"
# `find-identity -v` only lists trusted certs; self-signed ones aren't auto-trusted,
# so check the full list (without -v) — codesign can still use untrusted local certs.
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "› Signing with stable identity '${IDENTITY}'..."
    # Pin the Designated Requirement to the cert's Common Name so TCC permissions
    # persist across rebuilds (without this, the DR includes the CDHash → each
    # rebuild looks like a new app to TCC).
    DR="designated => identifier \"com.atem.SpeakIt\" and certificate leaf[subject.CN] = \"${IDENTITY}\""
    codesign --force --deep \
        --sign "${IDENTITY}" \
        --identifier com.atem.SpeakIt \
        --requirements "=${DR}" \
        "${APP_PATH}"
else
    echo "› Ad-hoc signing (run 'speakit setup-signing' once for persistent TCC perms)..."
    codesign --force --deep --sign - "${APP_PATH}"
fi

echo "› Registering with Launch Services..."
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"${LSREG}" -f "${APP_PATH}"

echo "› Refreshing Services registry..."
/System/Library/CoreServices/pbs -update

cat <<EOF

✓ Installed: ${APP_PATH}

Next steps:
  1. Kill any dev instance:   pkill -9 -f SpeakIt
  2. Launch the bundle:       open "${APP_PATH}"
  3. Grant Accessibility permission (TCC sees the .app as a fresh app —
     System Settings → Privacy & Security → Accessibility → add SpeakIt)
  4. Quit and relaunch once for permissions to take effect.

Services usage:
  Select text anywhere → right-click → Services → "Speak with SpeakIt"

  If the menu item is missing on first try:
    - Wait a few seconds (Services indexing is async)
    - Or: enable it manually in System Settings → Keyboard → Keyboard
      Shortcuts → Services → Text, look for "Speak with SpeakIt"
    - Worst case: log out and log back in (forces Services re-scan)
EOF
