#!/usr/bin/env bash
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
D="$ROOT/davo.sh"
TMP=$(mktemp -d)
SERVER_PID=''
trap '[[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

PASS='correct-horse-battery-staple'
TESTS=0
FAILURES=0

ok() {
    TESTS=$((TESTS + 1))
    printf 'ok %d - %s\n' "$TESTS" "$1"
}

not_ok() {
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'not ok %d - %s\n' "$TESTS" "$1"
}

run_test() {
    local name=$1; shift
    if "$@" >"$TMP/test.stdout" 2>"$TMP/test.stderr"; then
        ok "$name"
    else
        not_ok "$name"
        printf '  ---\n  stdout: %q\n  stderr: %q\n  ...\n' \
            "$(cat "$TMP/test.stdout")" "$(cat "$TMP/test.stderr")"
    fi
}

setup() {
    printf 'seed\n' > "$TMP/seed.txt"
    mkdir -p "$TMP/input/sub"
    printf 'hello\n' > "$TMP/input/hello.txt"
    printf 'world\n' > "$TMP/input/sub/world.txt"
    printf '%s\n' "$PASS" > "$TMP/password"
    printf 'wrong-password\n' > "$TMP/wrong"
    printf 'small file\n' > "$TMP/small.bin"

    # A deliberately fake local bundle lets the tests exercise bundle lookup
    # and source-map stripping without requiring the real OpenPGP.js download.
    printf '%s\n' '/* OpenPGP.js v6.3.1 test bundle */' '//# sourceMappingURL=openpgp.min.js.map' > "$TMP/openpgp.min.js"

    cat > "$TMP/upload_server.py" <<'PY'
import http.server
from urllib.parse import urlsplit, parse_qs
from email import policy
from email.parser import BytesParser
store = {}
seen = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        n = int(self.headers.get('Content-Length', '0'))
        data = self.rfile.read(n)
        path = self.path
        if path.startswith('/boba/fail/'):
            self.send_response(503); self.end_headers(); return
        if path.startswith('/boba/api/v1/upload/'):
            name = path.rsplit('/', 1)[-1]
            key = 'boba-' + str(len(store)); store[key] = data
            self.send_response(201)
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/boba/raw/{key}')
            self.end_headers(); return
        if path.startswith('/qurl/fail/'):
            self.send_response(503); self.end_headers(); return
        if path.startswith('/qurl/'):
            name = path.rsplit('/', 1)[-1]
            key = 'qurl-' + str(len(store)); store[key] = data
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(f'http://127.0.0.1:{self.server.server_port}/qurl/raw/{key}/{name}\n'.encode())
            return
        self.send_response(404); self.end_headers()
    def do_GET(self):
        parts = self.path.split('?')[0].split('/')
        key = next((x for x in reversed(parts) if x in store), None)
        if key:
            data = store[key]
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data); return
        self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY
    python3 "$TMP/upload_server.py" > "$TMP/port" & SERVER_PID=$!
    for _ in {1..50}; do [[ -s "$TMP/port" ]] && break; sleep .05; done
    PORT=$(cat "$TMP/port")
    export DAVO_BOBASHARE_URL="http://127.0.0.1:$PORT/boba"
    export DAVO_QURL_URL="http://127.0.0.1:$PORT/qurl"
    export PORT_BASE="http://127.0.0.1:$PORT"
}

run_test 'shell syntax' bash -n "$D"
run_test 'version is 1.2.0' bash -c "[[ \$(\"$D\" --version) == 'davo.sh 1.2.0' ]]"
run_test 'help shows -p as password string' bash -c "\"$D\" --help | grep -Fq -- '-p, --password STRING'"
run_test 'help shows -e as expiry shorthand' bash -c "\"$D\" --help | grep -Fq -- '-e, --expiry TIME'"
run_test 'help shows -P as password file' bash -c "\"$D\" --help | grep -Fq -- '-P, --password-file FILE'"
run_test 'help has five examples' bash -c "[[ \$(\"$D\" --help | awk '/^Examples:/{f=1;next} f && /^  /{n++} END{print n+0}') -eq 5 ]]"

setup
export D PASS TMP PORT_BASE

run_test 'random password is three words or 128-bit hex' bash -c '
  out=$("$D" encrypt "$TMP/seed.txt" --random-password -o "$TMP/random.gpg" 2>&1)
  p=$(printf "%s\n" "$out" | sed -n "s/^Password: //p" | tail -n1)
  [[ "$p" =~ ^[a-z]+-[a-z]+-[a-z]+$ || "$p" =~ ^[0-9a-f]{32}$ ]]
'

run_test '-p supplies a literal password' bash -c '
  "$D" encrypt "$TMP/seed.txt" -p "$PASS" -o "$TMP/p-string.gpg" >/dev/null
  "$D" decrypt "$TMP/p-string.gpg" -p "$PASS" -o "$TMP/p-string.out" >/dev/null
  cmp "$TMP/seed.txt" "$TMP/p-string.out"
'

run_test '-P reads a password file' bash -c '
  "$D" encrypt "$TMP/seed.txt" -P "$TMP/password" -o "$TMP/p-file.gpg" >/dev/null
  "$D" decrypt "$TMP/p-file.gpg" -P "$TMP/password" -o "$TMP/p-file.out" >/dev/null
  cmp "$TMP/seed.txt" "$TMP/p-file.out"
'

run_test '--password-file remains accepted' bash -c '
  "$D" encrypt "$TMP/seed.txt" --password-file "$TMP/password" -o "$TMP/long-file.gpg" >/dev/null
  "$D" decrypt "$TMP/long-file.gpg" --password-file "$TMP/password" -o "$TMP/long-file.out" >/dev/null
  cmp "$TMP/seed.txt" "$TMP/long-file.out"
'

run_test 'wrong password is rejected' bash -c '
  "$D" encrypt "$TMP/seed.txt" -p "$PASS" -o "$TMP/wrong-test.gpg" >/dev/null
  ! "$D" decrypt "$TMP/wrong-test.gpg" -P "$TMP/wrong" -o "$TMP/nope" >/dev/null 2>&1
'

run_test 'corrupt OpenPGP payload is rejected' bash -c '
  "$D" encrypt "$TMP/seed.txt" -p "$PASS" -o "$TMP/test.gpg" >/dev/null
  cp "$TMP/test.gpg" "$TMP/corrupt.gpg"
  printf "\\x00" | dd of="$TMP/corrupt.gpg" bs=1 seek=10 conv=notrunc status=none
  ! "$D" decrypt "$TMP/corrupt.gpg" -p "$PASS" -o "$TMP/nope2" >/dev/null 2>&1
'

run_test 'directory becomes a ZIP in HTML mode' bash -c '
  out=$(cd "$TMP" && "$D" send "$TMP/input" -p "$PASS" --backend bobashare --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  "$D" get "$url" -p "$PASS" -o "$TMP/html.recovered" >/dev/null
  unzip -tq "$TMP/html.recovered" >/dev/null
'

run_test 'embedded source-map reference is stripped' bash -c '
  out=$(cd "$TMP" && "$D" send "$TMP/input" -p "$PASS" --backend bobashare --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  curl -fsSL "$url" -o "$TMP/uploaded.html"
  ! grep -q sourceMappingURL "$TMP/uploaded.html"
'

run_test 'HTML filename is escaped for the script context' bash -c '
  printf "payload\n" > "$TMP/evil<img>.txt"
  out=$(cd "$TMP" && "$D" send "$TMP/evil<img>.txt" -p "$PASS" --backend qurl --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  curl -fsSL "$url" -o "$TMP/escaped.html"
  grep -Fq "\\u003cimg\\u003e" "$TMP/escaped.html"
'



run_test 'explicit qurl backend works' bash -c '
  out=$(cd "$TMP" && "$D" send "$TMP/input" -p "$PASS" --backend qurl --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  [[ "$url" == http://127.0.0.1:*/qurl/raw/* ]]
  "$D" get "$url" -p "$PASS" -o "$TMP/qurl.recovered" >/dev/null
  unzip -tq "$TMP/qurl.recovered" >/dev/null
'

run_test '0x0 backend is rejected' bash -c '
  ! (cd "$TMP" && "$D" send "$TMP/small.bin" -p "$PASS" --backend 0x0) >/dev/null 2>"$TMP/zero.err"
  grep -Fq "unknown backend: 0x0" "$TMP/zero.err"
'

run_test 'qurl rejects unsupported long expiry' bash -c '
  ! (cd "$TMP" && "$D" send "$TMP/small.bin" -p "$PASS" --backend qurl --expiry 8d) >/dev/null 2>"$TMP/qurl-expiry.err"
  grep -Fq "qurl.sh supports uploads for at most 7 days" "$TMP/qurl-expiry.err"
'

run_test 'qurl rejects non-expiring uploads' bash -c '
  ! (cd "$TMP" && "$D" send "$TMP/small.bin" -p "$PASS" --backend qurl --expiry 0) >/dev/null 2>"$TMP/qurl-noexpiry.err"
  grep -Fq "qurl.sh does not support non-expiring uploads" "$TMP/qurl-noexpiry.err"
'

run_test 'auto backend falls back from BobaShare to qurl' bash -c '
  export DAVO_BOBASHARE_URL="$PORT_BASE/boba/fail"
  out=$(cd "$TMP" && "$D" send "$TMP/input" -p "$PASS" --expiry 1h 2>"$TMP/fallback.err")
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  grep -Fq "BobaShare upload failed; trying the next backend." "$TMP/fallback.err"
  [[ "$url" == http://127.0.0.1:*/qurl/raw/* ]]
'
run_test 'auto backend stops after qurl failure' bash -c '
  export DAVO_BOBASHARE_URL="$PORT_BASE/boba/fail"
  export DAVO_QURL_URL="$PORT_BASE/qurl/fail"
  ! (cd "$TMP" && "$D" send "$TMP/small.bin" -p "$PASS" --expiry 1h) >/dev/null 2>"$TMP/auto.err"
  grep -Fq "BobaShare upload failed; trying the next backend." "$TMP/auto.err"
  grep -Fq "qurl.sh upload failed." "$TMP/auto.err"
'
export DAVO_BOBASHARE_URL="http://127.0.0.1:$PORT/boba"


run_test '--no-html uploads a raw encrypted link' bash -c '
  out=$(cd "$TMP" && "$D" send "$TMP/small.bin" -p "$PASS" --no-html --backend qurl --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  [[ "$url" == http://127.0.0.1:*/qurl/raw/* ]]
  "$D" get "$url" -p "$PASS" -o "$TMP/raw-get.recovered" >/dev/null
  cmp "$TMP/small.bin" "$TMP/raw-get.recovered"
'

run_test 'get rejects a missing password' bash -c '
  ! "$D" get http://127.0.0.1:1/not-used >/dev/null 2>"$TMP/get.err"
  grep -Fq "a passphrase is required when decrypting" "$TMP/get.err"
'

run_test 'small file is sent without ZIP wrapping' bash -c '
  out=$(cd "$TMP" && "$D" send "$TMP/small.bin" -p "$PASS" --backend bobashare --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  "$D" get "$url" -p "$PASS" -o "$TMP/small.recovered" >/dev/null
  cmp "$TMP/small.bin" "$TMP/small.recovered"
'

run_test 'file just over 10 MiB is ZIP wrapped' bash -c '
  head -c $((10 * 1024 * 1024 + 1)) /dev/urandom > "$TMP/big.bin"
  out=$(cd "$TMP" && "$D" send "$TMP/big.bin" -p "$PASS" --backend bobashare --expiry 1h)
  url=$(printf "%s\n" "$out" | sed -n "s/^URL: //p")
  "$D" get "$url" -p "$PASS" -o "$TMP/big.recovered.zip" >/dev/null
  unzip -tq "$TMP/big.recovered.zip" >/dev/null
'

run_test 'blank interactive password generates one' bash -c '
  out=$(printf "\\n" | "$D" encrypt "$TMP/seed.txt" -o "$TMP/blank.gpg" 2>&1)
  printf "%s\n" "$out" | grep -Eq "^Generated passphrase: ([a-z]+-[a-z]+-[a-z]+|[0-9a-f]{32})$"
'

run_test '--random-password is rejected for get' bash -c '
  ! "$D" get http://127.0.0.1:1/not-used --random-password >/dev/null 2>"$TMP/random-get.err"
  grep -Fq "cannot be used for decryption" "$TMP/random-get.err"
'

run_test 'windows launcher is standalone and does not bypass execution policy' bash -c "grep -Fq 'powershell.exe -NoLogo -NoProfile -Command' '$ROOT/davo.cmd' && grep -Fq '# --- POWERSHELL PAYLOAD ---' '$ROOT/davo.cmd' && ! grep -Fq -- '-ExecutionPolicy Bypass' '$ROOT/davo.cmd' && ! grep -Fq 'DAVO_PS1' '$ROOT/davo.cmd'"

printf '\n1..%d\n' "$TESTS"
if (( FAILURES )); then
    printf '%d test(s) failed.\n' "$FAILURES" >&2
    exit 1
fi
printf 'davo.sh tests: PASS (%d tests)\n' "$TESTS"
