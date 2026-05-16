#!/usr/bin/env bash
# One-time setup: create a stable self-signed code-signing identity in the
# login keychain so SpeakIt rebuilds preserve TCC (Accessibility, Input
# Monitoring) permissions. After this runs once, every `speakit build` signs
# with the same identity → same CDHash family → TCC entries persist.
set -euo pipefail

IDENTITY_NAME="SpeakIt Self-Signed"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ Identity '$IDENTITY_NAME' already exists."
    exit 0
fi

echo "→ Generating self-signed code-signing certificate…"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_req

[dn]
CN = $IDENTITY_NAME

[v3_req]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

# Prefer Homebrew's OpenSSL 3.x (supports `-legacy`) over macOS's LibreSSL,
# which writes PKCS12 macOS's own `security` tool can't decrypt.
OPENSSL=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/bin/openssl; do
    if [[ -x "$candidate" ]]; then
        OPENSSL="$candidate"
        break
    fi
done
[[ -n "$OPENSSL" ]] || { echo "✗ openssl not found"; exit 1; }
echo "  using: $OPENSSL ($("$OPENSSL" version))"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" \
    -out    "$TMP/cert.pem" \
    -days   36500 \
    -config "$TMP/openssl.cnf" 2>/dev/null

# Use a real password — empty-password PKCS12 import is unreliable across
# OpenSSL/LibreSSL versions on macOS. The password only protects the p12
# file (which we delete immediately); the keychain entry itself doesn't need it.
PASS="speakit"

# Try modern OpenSSL 3 path with `-legacy` first; fall back to explicit
# legacy cipher selection (works on LibreSSL).
"$OPENSSL" pkcs12 -export -legacy \
    -inkey   "$TMP/key.pem" \
    -in      "$TMP/cert.pem" \
    -out     "$TMP/identity.p12" \
    -passout "pass:$PASS" 2>/dev/null \
  || "$OPENSSL" pkcs12 -export \
       -keypbe  PBE-SHA1-3DES \
       -certpbe PBE-SHA1-3DES \
       -macalg  SHA1 \
       -inkey   "$TMP/key.pem" \
       -in      "$TMP/cert.pem" \
       -out     "$TMP/identity.p12" \
       -passout "pass:$PASS"

echo "→ Importing into login keychain (macOS will ask for your login password)…"
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A

# Let codesign use the key without GUI prompts.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -k "" \
    "$KEYCHAIN" >/dev/null 2>&1 || true

echo
echo "✓ Created identity: '$IDENTITY_NAME'"
security find-identity -p codesigning -v | grep "$IDENTITY_NAME" || true
echo
echo "Next: 'speakit build' will now sign with this identity."
echo "After the first build, grant Accessibility + Input Monitoring once — they'll persist."
