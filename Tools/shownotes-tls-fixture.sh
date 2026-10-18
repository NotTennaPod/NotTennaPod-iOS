#!/bin/zsh
# Generates the show-notes view tests' loopback TLS certificates (ShownotesSubresourceTests). The view-test scheme's
# pre-action runs it before every test run; it can also be run by hand. The certificates and keys are made fresh for
# 127.0.0.1, live only in this checkout's ignored .work folder and are never committed. Nothing is added to a trust
# store: a debug-only hook in the notes trusts exactly the "trusted" certificate's fingerprint; "other" is the control
# a test expects to be rejected.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-.work/test-fixtures/shownotes-tls}
mkdir -p "$OUT"; chmod 700 "$OUT"
for name in trusted other; do
  cat > "$OUT/$name.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = 127.0.0.1
[ext]
subjectAltName = IP:127.0.0.1
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$OUT/$name.cnf" \
    -keyout "$OUT/$name.key" -out "$OUT/$name.pem" 2>/dev/null
  # The PKCS #12 passphrase only satisfies the import API; the files never leave this machine.
  /usr/bin/openssl pkcs12 -export -inkey "$OUT/$name.key" -in "$OUT/$name.pem" -name "$name" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -passout pass:fixture -out "$OUT/$name.p12"
done
echo "Show-notes TLS fixture certificates in $OUT"
