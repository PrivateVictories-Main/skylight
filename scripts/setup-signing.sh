#!/bin/zsh
# One-time: create a local "Skylight Dev" code-signing identity so macOS
# remembers permission grants across rebuilds. Run once; approve the one
# trust dialog if it appears. Idempotent.
set -euo pipefail

if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Skylight Dev"'; then
  echo "Skylight Dev identity already exists — nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# openssl failures keep their stderr: under `set -e` this script dies here, and
# it must be able to say why.
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -subj "/CN=Skylight Dev" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null

openssl pkcs12 -export -out "$WORK/skylight.p12" -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" -passout pass:skylight-dev >/dev/null

security import "$WORK/skylight.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P skylight-dev -T /usr/bin/codesign >/dev/null

# Let codesign use the key without the keychain asking every time. `-k ""`
# makes this prompt once for your login password — that belongs to this
# one-time setup, and is exactly why it must not live in the build path.
security set-key-partition-list -S "apple-tool:,apple:" -s -k "" \
  "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || {
  echo "note: partition-list step skipped — the FIRST build may show one"
  echo "      'codesign wants to access key' prompt; click Always Allow."
}

# Trust it for code signing (user domain; may show one auth dialog).
security add-trusted-cert -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem" || {
  echo "Trust step skipped — signing may still work; if codesign complains,"
  echo "open Keychain Access → login → Skylight Dev → Trust → Code Signing: Always."
}

# Say which outcome actually happened. A declined trust dialog leaves an
# imported-but-unusable identity, and reporting that as "Done" would send Ryan
# off to rebuild for a benefit he did not get.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Skylight Dev"'; then
  echo "Done. Rebuild the app (scripts/make-app.sh) — grants now persist."
else
  echo "Identity imported but NOT yet trusted for code signing."
  echo "Open Keychain Access → login → Skylight Dev → Get Info → Trust → Code Signing: Always Trust, then re-run this script to confirm."
  exit 1
fi
