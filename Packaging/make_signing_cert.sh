#!/bin/bash
# Create a local, self-signed code-signing identity for VoicePlus.
#
# WHY THIS EXISTS
#   TCC does not remember "VoicePlus may listen to key events". It remembers the app's *designated
#   requirement* at the moment the switch was turned on, and re-evaluates that requirement on every
#   later query. A plain ad-hoc signature has no certificate and no Team ID, so its requirement
#   degrades to `cdhash H"<this exact binary>"` — a new value on every build. The next build fails
#   the stored requirement, tccd answers "not granted", and System Settings still shows the switch
#   as on, because the switch (`auth_value`) and the requirement (`csreq`) are different columns.
#   That is the whole 1.6.3 "Input Monitoring is on but the app says it is off" report.
#
#   A self-signed certificate fixes it without any Apple Developer Program membership: the signature
#   gains a stable leaf, codesign's designated requirement becomes `identifier "…" and certificate
#   leaf H"…"`, and the leaf hash is a property of the certificate rather than of the binary. Grants
#   then survive every rebuild.
#
#   make_app.sh does not need this script: without a valid identity it falls back to ad-hoc *plus an
#   explicit, build-independent designated requirement*, which also keeps grants across rebuilds.
#   The certificate is the stronger version of the same idea — it cannot be claimed by some other
#   locally signed binary that reuses our bundle id.
#
# Usage:  Packaging/make_signing_cert.sh [certificate-name]
# Env:    CODESIGN_CERT_NAME (default "VoicePlus Local Signing")
# Exit:   0  a valid, trusted code-signing identity of that name exists — builds will use it
#         3  the certificate exists but is not trusted yet; the ONE command you must run is printed
#         1  something went wrong
#
# This script never asks for, stores or prints a password, and never signs anything. The one step it
# cannot do for you is trusting the certificate: that writes to the system trust store and needs an
# administrator password, so it is printed for you to run yourself.
set -euo pipefail

NAME="${1:-${CODESIGN_CERT_NAME:-VoicePlus Local Signing}}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_DIR="$HOME/Library/Application Support/VoicePlus"
CERT_PATH="$CERT_DIR/$NAME.cer"

log() { printf '\033[1;34m[signing-cert]\033[0m %s\n' "$*"; }

trust_instructions() {
  cat <<EOF

  ---------------------------------------------------------------------------
  ONE-TIME STEP, and it has to be you: codesign refuses an untrusted identity
  ("$NAME: no identity found", find-identity reports CSSMERR_TP_NOT_TRUSTED).
  Trusting a certificate writes to the system trust store, so it needs your
  administrator password.

  Run this once:

    sudo security add-trusted-cert -d -r trustRoot -p codeSign \\
      -k /Library/Keychains/System.keychain "$CERT_PATH"

  Or, without sudo: open "$CERT_PATH" in Keychain Access, double-click the
  certificate, expand "Trust", and set "Code Signing" to "Always Trust".

  Then check it took:

    security find-identity -v -p codesigning    # must list "$NAME"

  Until then builds keep working — make_app.sh falls back to ad-hoc signing with
  an explicit designated requirement (see Packaging/SIGNING.md §4).
  ---------------------------------------------------------------------------
EOF
}

# --- Already usable? ---------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
  log "\"$NAME\" is already a valid code-signing identity — nothing to do."
  log "build with it:  CODESIGN_IDENTITY=\"$NAME\" Packaging/make_app.sh <version>"
  exit 0
fi

# --- Present but untrusted? --------------------------------------------------
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
  log "\"$NAME\" exists in the keychain but is not trusted for code signing yet."
  trust_instructions
  exit 3
fi

# --- Create it ---------------------------------------------------------------
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/voiceplus-signing.XXXXXX")"
# The private key only ever exists inside this directory, and only until the keychain has it.
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

log "generating a self-signed code-signing certificate: $NAME"
cat > "$TMP/req.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/req.cnf" >/dev/null 2>&1

# A one-shot passphrase that exists for the length of this pipeline and is never written to disk.
# NOTE: the legacy PBE/MAC algorithms are not optional — macOS' `security import` cannot read
# OpenSSL 3's defaults and fails with "MAC verification failed during PKCS12 import (wrong
# password?)", which looks like a typo and is not one. Measured on this machine.
P12PASS="$(openssl rand -hex 24)"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out "$TMP/identity.p12" -passout "pass:$P12PASS" >/dev/null 2>&1

log "importing into the login keychain (codesign is pre-authorised for the key)"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign >/dev/null

mkdir -p "$CERT_DIR"
openssl x509 -in "$TMP/cert.pem" -outform der -out "$CERT_PATH"
log "certificate kept at: $CERT_PATH"
log "  (copy it to another build machine and trust it there to get the same identity)"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
  log "identity is valid already — build with:"
  log "  CODESIGN_IDENTITY=\"$NAME\" Packaging/make_app.sh <version>"
  exit 0
fi

trust_instructions
exit 3
