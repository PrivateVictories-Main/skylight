#!/bin/zsh
# One-time: create a local "Skylight Dev" code-signing identity so macOS
# remembers permission grants across rebuilds. Run once; approve the one
# trust dialog if it appears. Idempotent.
set -euo pipefail

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Skylight Dev"; then
  echo "Skylight Dev identity already exists — nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -subj "/CN=Skylight Dev" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -out "$WORK/skylight.p12" -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" -passout pass:skylight-dev >/dev/null 2>&1

security import "$WORK/skylight.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P skylight-dev -T /usr/bin/codesign >/dev/null

# Trust it for code signing (user domain; may show one auth dialog).
security add-trusted-cert -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem" || {
  echo "Trust step skipped — signing may still work; if codesign complains,"
  echo "open Keychain Access → login → Skylight Dev → Trust → Code Signing: Always."
}

echo "Done. Rebuild the app (scripts/make-app.sh) — grants now persist."
