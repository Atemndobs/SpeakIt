#!/usr/bin/env bash
# Build, zip, upload, and update the Homebrew Cask for a new SpeakIt release.
# Usage: ./scripts/release.sh <version>   (e.g. ./scripts/release.sh 0.3.0)
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${HOME}/Applications/SpeakIt.app"
ZIP="/tmp/SpeakIt-${VERSION}.zip"
CASK="${REPO_ROOT}/Casks/speakit.rb"

cd "${REPO_ROOT}"

echo "› Building .app..."
./scripts/build-app.sh

echo "› Zipping bundle → ${ZIP}"
rm -f "${ZIP}"
(cd "${HOME}/Applications" && /usr/bin/ditto -c -k --keepParent SpeakIt.app "${ZIP}")

SHA="$(/usr/bin/shasum -a 256 "${ZIP}" | awk '{print $1}')"
echo "› sha256: ${SHA}"

echo "› Updating ${CASK}"
/usr/bin/sed -i '' -E "s|^  version \".*\"|  version \"${VERSION}\"|" "${CASK}"
/usr/bin/sed -i '' -E "s|^  sha256 \"[a-f0-9]+\"|  sha256 \"${SHA}\"|" "${CASK}"

echo "› Creating GitHub release v${VERSION}"
gh release create "v${VERSION}" "${ZIP}" \
  --title "v${VERSION}" \
  --notes "See [README](../README.md) for install instructions."

echo
echo "✓ Released v${VERSION}"
echo "  Don't forget to commit + tag the Cask update:"
echo "    git add Casks/speakit.rb && git commit -m 'release: v${VERSION}'"
echo "    git tag v${VERSION} && git push --tags"
