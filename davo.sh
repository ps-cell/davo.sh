#!/usr/bin/env bash
set -euo pipefail
umask 077

VERSION='1.2.0'
BOBASHARE_URL="${DAVO_BOBASHARE_URL:-https://share.boba.best}"
QURL_URL="${DAVO_QURL_URL:-https://qurl.sh}"
EXPIRY="${DAVO_EXPIRY:-1h}"
BOBASHARE_MAX_UPLOAD=$((1024 * 1024 * 1024))
QURL_MAX_UPLOAD=$((500 * 1024 * 1024))
BOBASHARE_MAX_INPUT=$((BOBASHARE_MAX_UPLOAD * 3 / 4 - 4 * 1024 * 1024))
QURL_MAX_INPUT=$((QURL_MAX_UPLOAD * 3 / 4 - 4 * 1024 * 1024))
BOBASHARE_MAX_EXPIRY=$((30 * 86400))
QURL_MAX_EXPIRY=$((7 * 86400))
ARCHIVE_THRESHOLD=$((10 * 1024 * 1024))
S2K_COUNT=65011712
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OPENPGP_VERSION='6.3.1'
OPENPGP_URL_DEFAULT="https://unpkg.com/openpgp@${OPENPGP_VERSION}/dist/openpgp.min.js"
OPENPGP_URL_FALLBACK="https://cdn.jsdelivr.net/npm/openpgp@${OPENPGP_VERSION}/dist/openpgp.min.js"
OPENPGP_BUNDLE="${DAVO_OPENPGP_BUNDLE:-}"
OPENPGP_URL="${DAVO_OPENPGP_URL:-}"
OPENPGP_SHA256="${DAVO_OPENPGP_SHA256:-}"
OPENPGP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/davo.sh/openpgp-${OPENPGP_VERSION}.min.js"
WORDLIST_URL="${DAVO_WORDLIST_URL:-https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt}"
WORDLIST_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/davo.sh/wordlist-7776.txt"

TMPDIR_DAVO=''
cleanup() { [[ -z "$TMPDIR_DAVO" ]] || rm -rf -- "$TMPDIR_DAVO"; }
trap cleanup EXIT INT TERM

die() { printf 'davo.sh: error: %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
davo.sh — simple encrypted file transport

Usage:
  davo.sh send <file|directory> [options]
  davo.sh get <url> [options]
  davo.sh encrypt <file> [options]
  davo.sh decrypt <file> [options]

Commands:
  send       Encrypt a file or directory and upload it (HTML by default, or raw with --no-html).
  get        Download an HTML or raw encrypted link and recover the original file locally.
  encrypt    Create a local symmetric OpenPGP payload.
  decrypt    Decrypt a local OpenPGP payload.

Options:
  -p, --password STRING      Use STRING as the password.
  -P, --password-file FILE   Read the password from FILE.
      --password-env         Read the password from DAVO_PASSWORD.
      --random-password      Generate and print a random three-word password.
      --no-html               Upload the encrypted OpenPGP file directly instead of an HTML decryptor.
      --backend NAME          Use bobashare or qurl (default: auto; tries both).
  -o, --output FILE          Output file.
  -f, --force                Overwrite an existing output file.
  -e, --expiry TIME         Upload expiry (default: 1h).
  -h, --help                 Show this help.
      --version              Show the version.

Environment:
  DAVO_PASSWORD        Password used with --password-env.
  DAVO_BACKEND          Default backend: auto, bobashare, or qurl.
  DAVO_EXPIRY          Default upload expiry.
  DAVO_OPENPGP_BUNDLE  Use a local OpenPGP.js 6.3.1 browser bundle.
  DAVO_OPENPGP_URL     Override the default exact-version bundle URL.
  DAVO_OPENPGP_SHA256  Optionally require an exact bundle SHA-256.
  DAVO_WORDLIST_URL     Override the password word-list URL.

davo.sh uses standard symmetric OpenPGP with AES-256 and iterated+salted
  SHA-256 S2K. Directories and files over 10 MiB are zipped first; smaller
  files are sent as-is. By default the recipient gets a self-contained HTML
  decryptor. With --no-html, the encrypted OpenPGP file itself is uploaded,
  which is handy for curl and other command-line workflows.

  Generated passphrases use a standard 7776-word Diceware list fetched over
  HTTPS and cached locally. If the list cannot be fetched, davo.sh falls back
  to a 32-character random hexadecimal passphrase.

  BobaShare currently accepts uploads up to 1 GiB; qurl.sh accepts up to 500 MiB;
  davo.sh accounts for HTML/base64 overhead when deciding whether a backend can
  carry a file. With the default auto backend, it tries BobaShare, then qurl.sh.

Examples:
  davo.sh send project.zip
  davo.sh send project-directory --backend qurl
  davo.sh send project.zip -p 'correct horse battery staple'
  davo.sh get 'https://...' -P password.txt
  davo.sh encrypt project.zip -o project.gpg
USAGE
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
size_of() { stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1"; }
url_encode_segment() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

password() {
    local supplied='' file='' from_env=0 random=0 interactive=1
    while (($#)); do
        case "$1" in
            --string) (($# >= 2)) || die "$1 requires a string"; supplied=$2; shift 2;;
            --file) (($# >= 2)) || die "$1 requires a file"; file=$2; shift 2;;
            --env) from_env=1; shift;;
            --random) random=1; shift;;
            --required) interactive=0; shift;;
            *) die "internal password option error";;
        esac
    done

    if (( random )); then
        generate_password
    elif [[ -n "$supplied" ]]; then
        DAVO_PASSWORD=$supplied
    elif [[ -n "$file" ]]; then
        [[ -r "$file" ]] || die "cannot read password file: $file"
        IFS= read -r DAVO_PASSWORD < "$file" || true
    elif (( from_env )); then
        : "${DAVO_PASSWORD:?DAVO_PASSWORD is empty}"
    elif (( interactive == 0 )); then
        die 'a passphrase is required when decrypting; use --password-file or --password-env for non-interactive use'
    else
        # Deliberately echo the passphrase while typing.  This is a small
        # convenience tool, and it also makes the blank-to-generate behavior
        # discoverable without another prompt or option to remember.
        read -r -p 'Passphrase (leave blank to generate one): ' DAVO_PASSWORD
        printf '\n' >&2
        if [[ -z "${DAVO_PASSWORD:-}" ]]; then
            generate_password
            printf 'Generated passphrase: %s\n' "$DAVO_PASSWORD" >&2
            return
        fi
    fi
    printf 'Password: %s\n' "$DAVO_PASSWORD" >&2
}

# Fetch the standard 7776-entry Diceware list when needed. The list itself is
# public; only the randomly selected words form the passphrase. We require
# exactly 7776 unique entries so a broken or truncated download cannot silently
# reduce the generator's search space.
wordlist_file() {
    local tmp line word count
    if [[ -f "$WORDLIST_CACHE" ]]; then
        count=$(wc -l < "$WORDLIST_CACHE")
        if [[ "$count" -eq 7776 ]] && [[ "$(sort -u "$WORDLIST_CACHE" | wc -l)" -eq 7776 ]]; then
            printf '%s\n' "$WORDLIST_CACHE"
            return
        fi
        rm -f -- "$WORDLIST_CACHE"
    fi
    mkdir -p -- "$(dirname -- "$WORDLIST_CACHE")"
    tmp="$WORDLIST_CACHE.tmp.$$"
    if curl --fail --silent --show-error --location --connect-timeout 5 --max-time 15 "$WORDLIST_URL" -o "$tmp"; then
        awk 'NF >= 2 {print $2}' "$tmp" > "${tmp}.words"
        count=$(wc -l < "${tmp}.words")
        if [[ "$count" -eq 7776 ]] && [[ "$(sort -u "${tmp}.words" | wc -l)" -eq 7776 ]]; then
            mv -f -- "${tmp}.words" "$WORDLIST_CACHE"
            rm -f -- "$tmp"
            chmod 600 "$WORDLIST_CACHE"
            printf '%s\n' "$WORDLIST_CACHE"
            return
        fi
    fi
    rm -f -- "$tmp" "${tmp}.words"
    return 1
}

# Uniformly select three entries from a 7776-word list. Each word contributes
# log2(7776) ~= 12.925 bits, for ~38.8 bits total.
random_word() {
    local n=7776 hex value limit index word list
    if ! list=$(wordlist_file); then
        return 1
    fi
    limit=$(( (4294967296 / n) * n ))
    while :; do
        hex=$(openssl rand -hex 4)
        value=$((16#$hex))
        (( value < limit )) && break
    done
    index=$((value % n + 1))
    word=$(sed -n "${index}p" "$list")
    [[ -n "$word" ]] || return 1
    printf '%s' "$word"
}

generate_password() {
    local a b c
    if a=$(random_word) && b=$(random_word) && c=$(random_word); then
        DAVO_PASSWORD="$a-$b-$c"
    else
        # Offline fallback: 128 bits of random hex, with no word-list dependency.
        printf 'Word list unavailable; using a random 32-character fallback.\n' >&2
        DAVO_PASSWORD=$(openssl rand -hex 16) || die 'could not generate a random passphrase'
    fi
}

bundle_version_ok() {
    local file=$1
    grep -q "OpenPGP.js v${OPENPGP_VERSION}" "$file"
}

bundle_hash_ok() {
    local file=$1 actual
    [[ -z "$OPENPGP_SHA256" ]] && return 0
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$file" | awk '{print $1}')
    [[ "$actual" == "$OPENPGP_SHA256" ]]
}

select_openpgp_bundle() {
    local candidate
    if [[ -n "$OPENPGP_BUNDLE" ]]; then
        [[ -f "$OPENPGP_BUNDLE" ]] || die "OpenPGP.js bundle not found: $OPENPGP_BUNDLE"
        bundle_version_ok "$OPENPGP_BUNDLE" || die "OpenPGP.js bundle is not version ${OPENPGP_VERSION}: $OPENPGP_BUNDLE"
        bundle_hash_ok "$OPENPGP_BUNDLE" || die "OpenPGP.js bundle SHA-256 does not match DAVO_OPENPGP_SHA256"
        printf '%s\n' "$OPENPGP_BUNDLE"
        return
    fi
    for candidate in "$PWD/openpgp.min.js" "$ROOT/openpgp.min.js" "$OPENPGP_CACHE"; do
        if [[ -f "$candidate" ]] && bundle_version_ok "$candidate" && bundle_hash_ok "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    local url="${OPENPGP_URL:-$OPENPGP_URL_DEFAULT}" tmp
    mkdir -p "$(dirname -- "$OPENPGP_CACHE")"
    tmp="$OPENPGP_CACHE.tmp.$$"
    printf 'Downloading OpenPGP.js %s ...\n' "$OPENPGP_VERSION" >&2
    if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 120 "$url" -o "$tmp"; then
        rm -f -- "$tmp"
        if [[ -z "$OPENPGP_URL" ]]; then
            printf 'Primary CDN failed; trying fallback CDN ...\n' >&2
            if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 120 "$OPENPGP_URL_FALLBACK" -o "$tmp"; then
                rm -f -- "$tmp"
                die "could not obtain OpenPGP.js ${OPENPGP_VERSION}; use DAVO_OPENPGP_BUNDLE=/path/to/openpgp.min.js for offline/local use"
            fi
        else
            die "could not obtain OpenPGP.js ${OPENPGP_VERSION} from $url"
        fi
    fi
    if ! bundle_version_ok "$tmp" || ! bundle_hash_ok "$tmp"; then
        rm -f -- "$tmp"
        if [[ -n "$OPENPGP_SHA256" ]]; then
            die "downloaded OpenPGP.js bundle failed version or SHA-256 verification"
        fi
        die "downloaded OpenPGP.js bundle is not version ${OPENPGP_VERSION}"
    fi
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$OPENPGP_CACHE"
    printf '%s\n' "$OPENPGP_CACHE"
}

parse_options() {
    PASSWORD_STRING=''
    PASSWORD_FILE=''
    PASSWORD_ENV=0
    RANDOM_PASSWORD=0
    OUTPUT=''
    FORCE=0
    NO_HTML=0
    BACKEND="${DAVO_BACKEND:-auto}"
    while (($#)); do
        case "$1" in
            -p|--password) (($# >= 2)) || die "$1 requires a password"; PASSWORD_STRING=$2; shift 2;;
            -P|--password-file) (($# >= 2)) || die "$1 requires a file"; PASSWORD_FILE=$2; shift 2;;
            --password-env) PASSWORD_ENV=1; shift;;
            --random-password) RANDOM_PASSWORD=1; shift;;
            -o|--output) (($# >= 2)) || die "$1 requires a file"; OUTPUT=$2; shift 2;;
            -f|--force) FORCE=1; shift;;
            --no-html) NO_HTML=1; shift;;
            --backend) (($# >= 2)) || die "$1 requires a backend name"; BACKEND=$2; shift 2;;
            -e|--expiry) (($# >= 2)) || die "$1 requires a duration"; EXPIRY=$2; shift 2;;
            -h|--help) usage; exit 0;;
            --version) printf 'davo.sh %s\n' "$VERSION"; exit 0;;
            *) die "unknown option: $1";;
        esac
    done
}

set_password() {
    local required=${1:-0}
    if (( required )); then
        if (( RANDOM_PASSWORD )); then die '--random-password cannot be used for decryption'; fi
        if [[ -n "$PASSWORD_STRING" ]]; then password --string "$PASSWORD_STRING"
        elif [[ -n "$PASSWORD_FILE" ]]; then password --file "$PASSWORD_FILE"
        elif (( PASSWORD_ENV )); then password --env
        else password --required
        fi
    elif (( RANDOM_PASSWORD )); then password --random
    elif [[ -n "$PASSWORD_STRING" ]]; then password --string "$PASSWORD_STRING"
    elif [[ -n "$PASSWORD_FILE" ]]; then password --file "$PASSWORD_FILE"
    elif (( PASSWORD_ENV )); then password --env
    else password
    fi
}

check_output() { [[ -z "$1" || ! -e "$1" || $FORCE == 1 ]] || die "output exists: $1 (use --force to overwrite)"; }

make_password_file() {
    printf '%s\n' "$DAVO_PASSWORD" > "$TMPDIR_DAVO/password"
    chmod 600 "$TMPDIR_DAVO/password"
}

gpg_encrypt() {
    local input=$1 output=$2
    gpg --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-file "$TMPDIR_DAVO/password" \
        --symmetric --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA256 \
        --s2k-count "$S2K_COUNT" --compress-algo none --output "$output" "$input" \
        || die 'OpenPGP encryption failed'
}

gpg_decrypt() {
    local input=$1 output=$2
    gpg --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-file "$TMPDIR_DAVO/password" \
        --output "$output" --decrypt "$input" \
        || die 'OpenPGP decryption failed (wrong password or corrupt payload)'
}

zip_input() {
    local input=$1 output=$2 base
    if [[ -f "$input" ]]; then
        case "$input" in
            *.zip) cp -- "$input" "$output";;
            *)
                base=$(basename -- "$input")
                (cd "$(dirname -- "$input")" && zip -q -X "$output" "$base") || die 'ZIP creation failed'
                ;;
        esac
    elif [[ -d "$input" ]]; then
        base=$(basename -- "$input")
        (cd "$(dirname -- "$input")" && zip -qr -X "$output" "$base") || die 'ZIP creation failed'
    else
        die "not a regular file or directory: $input"
    fi
}

render_html() {
    local payload=$1 filename=$2 output=$3 created_at=$4 expires_at=$5 bundle sha
    bundle=$(select_openpgp_bundle)
    sha=$(sha256sum "$bundle" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$bundle" | awk '{print $1}')
    python3 - "$payload" "$filename" "$output" "$bundle" "$sha" "$created_at" "$expires_at" <<'PY'
from pathlib import Path
import base64, json, re, sys
payload=Path(sys.argv[1]); filename=Path(sys.argv[2]); output=Path(sys.argv[3]); bundle=Path(sys.argv[4]); sha=sys.argv[5]; created_at=int(sys.argv[6]); expires_at=int(sys.argv[7])
js=bundle.read_text(encoding='utf-8')
# The bundle may carry a sourceMappingURL. Once the JS is embedded inline,
# that turns into a relative file request against the recipient's HTML file.
# Strip it so the decryptor is genuinely self-contained and portable.
js=re.sub(r'\n?//# sourceMappingURL=.*?(?:\r?\n|$)', '\n', js)
data=base64.b64encode(payload.read_bytes()).decode('ascii')
name=json.dumps(filename.name, ensure_ascii=False).replace('<', r'\u003c').replace('>', r'\u003e').replace('&', r'\u0026').replace('\u2028', r'\u2028').replace('\u2029', r'\u2029')
page=r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>davo.sh encrypted file</title>
<style>
:root { color-scheme: light dark; font-family: system-ui, sans-serif; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
main { width: min(32rem, calc(100vw - 2rem)); padding: 2rem; box-sizing: border-box; }
h1 { font-size: 1.35rem; margin: 0 0 .5rem; }
p { opacity: .75; }
label { display: block; margin: 1.5rem 0 .4rem; }
input, button { box-sizing: border-box; width: 100%; padding: .75rem; font: inherit; }
button { margin-top: .8rem; cursor: pointer; }
#status { min-height: 1.5em; margin-top: 1rem; }
</style>
</head>
<body>
<main>
<h1>davo.sh encrypted file</h1>
<p>This file decrypts locally in your browser. Nothing is uploaded.</p>
<label for="password">Passphrase</label>
<input id="password" type="password" autocomplete="off" autofocus>
<button id="decrypt" type="button">Decrypt</button>
<p id="status" role="status" aria-live="polite"></p>
</main>
<script>
/* OpenPGP.js 6.3.1 — LGPL-3.0+ — SHA-256: __OPENPGP_SHA256__ */
__OPENPGP_BUNDLE__
</script>
<script>
'use strict';
const DAVO_PAYLOAD_B64 = '__DAVO_PAYLOAD__';
const DAVO_FILENAME = __DAVO_FILENAME__;
const DAVO_CREATED_AT = __DAVO_CREATED_AT__;
const DAVO_EXPIRES_AT = __DAVO_EXPIRES_AT__;
function expired() { return DAVO_EXPIRES_AT !== 0 && Math.floor(Date.now() / 1000) >= DAVO_EXPIRES_AT; }
function checkExpiry() { if (expired()) { button.disabled = true; password.disabled = true; setStatus('This davo.sh file has expired.'); return false; } return true; }
const button = document.getElementById('decrypt');
const password = document.getElementById('password');
const status = document.getElementById('status');
function setStatus(text) { status.textContent = text; }
function decodeBase64(s) {
  const raw = atob(s);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
async function decryptFile() {
  if (!checkExpiry()) return;
  const pass = password.value;
  if (!pass) { setStatus('Enter the passphrase.'); password.focus(); return; }
  button.disabled = true; password.disabled = true; setStatus('Decrypting locally…');
  try {
    if (!globalThis.openpgp) throw new Error('OpenPGP implementation is unavailable');
    const encrypted = decodeBase64(DAVO_PAYLOAD_B64);
    const message = await openpgp.readMessage({ binaryMessage: encrypted });
    const result = await openpgp.decrypt({ message, passwords: [pass], format: 'binary' });
    const data = result.data instanceof Uint8Array ? result.data : new Uint8Array(result.data);
    const url = URL.createObjectURL(new Blob([data], { type: 'application/octet-stream' }));
    const a = document.createElement('a'); a.href = url; a.download = DAVO_FILENAME;
    document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 60000);
    setStatus('Decrypted successfully. Your download should start shortly.');
  } catch (error) {
    console.error(error); setStatus('Could not decrypt the file. Check the passphrase or the file integrity.');
    password.disabled = false; password.select();
  } finally { button.disabled = false; }
}
button.addEventListener('click', decryptFile);
password.addEventListener('keydown', e => { if (e.key === 'Enter') decryptFile(); });
checkExpiry();
</script>
</body>
</html>
'''
page=page.replace('__OPENPGP_SHA256__',sha).replace('__OPENPGP_BUNDLE__',js).replace('__DAVO_PAYLOAD__',data).replace('__DAVO_FILENAME__',name).replace('__DAVO_CREATED_AT__',str(created_at)).replace('__DAVO_EXPIRES_AT__',str(expires_at))
output.write_text(page,encoding='utf-8')
PY
}

backend_expiry_limit() {
    case "$1" in
        bobashare) printf '%s\n' "$BOBASHARE_MAX_EXPIRY";;
        qurl) printf '%s\n' "$QURL_MAX_EXPIRY";;
    esac
}

validate_backend_expiry() {
    local seconds limit backend
    seconds=$(expiry_seconds "$EXPIRY")
    backend=$BACKEND
    case "$backend" in
        qurl)
            if (( seconds == 0 )); then
                die 'qurl.sh does not support non-expiring uploads'
            elif (( seconds > QURL_MAX_EXPIRY )); then
                die 'qurl.sh supports uploads for at most 7 days'
            fi
            ;;
        bobashare)
            limit=$(backend_expiry_limit "$backend")
            if (( seconds != 0 && seconds > limit )); then
                die "$(backend_name "$backend") supports uploads for at most $((limit / 86400)) days"
            fi
            ;;
        auto) ;;
        *) die "unknown backend: $BACKEND (choose auto, bobashare, or qurl)";;
    esac
}

backend_list() {
    local seconds backend limit
    seconds=$(expiry_seconds "$EXPIRY")
    case "$BACKEND" in
        auto)
            for backend in bobashare qurl; do
                limit=$(backend_expiry_limit "$backend")
                if (( seconds == 0 )) && [[ "$backend" == qurl ]]; then
                    continue
                fi
                if (( seconds != 0 && seconds > limit )); then
                    continue
                fi
                printf '%s\n' "$backend"
            done
            ;;
        bobashare|qurl)
            printf '%s\n' "$BACKEND"
            ;;
        *) die "unknown backend: $BACKEND (choose auto, bobashare, or qurl)";;
    esac
}

backend_name() {
    case "$1" in
        bobashare) printf 'BobaShare';;
        qurl) printf 'qurl.sh';;
    esac
}

upload_bobashare() {
    local payload=$1 name=$2 content_type=${3:-application/octet-stream}
    local response="$TMPDIR_DAVO/headers" location
    curl --fail-with-body --silent --show-error -X PUT \
        -H "Content-Type: $content_type" \
        -H "Bobashare-Expiry: $EXPIRY" \
        --data-binary "@$payload" -D "$response" -o "$TMPDIR_DAVO/response" \
        "$BOBASHARE_URL/api/v1/upload/$(url_encode_segment "$name")" || {
        cat "$TMPDIR_DAVO/response" >&2 2>/dev/null || true
        return 1
    }
    location=$(awk 'BEGIN{IGNORECASE=1} /^Location:/ {sub(/\r$/,"",$0); sub(/^[^:]*:[[:space:]]*/,"",$0); print; exit}' "$response")
    if [[ -n "$location" ]]; then
        if [[ "$location" == *'?'* ]]; then
            printf '%s\n' "$location"
        else
            printf '%s?download\n' "$location"
        fi
        return 0
    fi
    location=$(sed -n 's/.*"direct_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMPDIR_DAVO/response" | head -n1)
    if [[ -n "$location" ]]; then
        if [[ "$location" == *'?'* ]]; then printf '%s\n' "$location"; else printf '%s?download\n' "$location"; fi
        return 0
    fi
    return 1
}

upload_qurl() {
    local payload=$1 name=$2 content_type=${3:-application/octet-stream}
    local response
    response=$(curl --fail-with-body --silent --show-error --location \
        -T "$payload" \
        -H "X-TTL: $EXPIRY" \
        -H 'X-Format: url' \
        -H "Content-Type: $content_type" \
        "$QURL_URL/$(url_encode_segment "$name")") || {
        return 1
    }
    response=$(printf '%s\n' "$response" | grep -Eo 'https?://[^[:space:]"<>]+' | tail -n1 || true)
    [[ -n "$response" ]] || return 1
    printf '%s\n' "$response"
}

expiry_seconds() {
    local expiry=$1 n unit
    [[ $expiry == 0 ]] && { printf '0\n'; return; }
    if [[ $expiry =~ ^([0-9]+)(m|h|d)$ ]]; then
        n=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}
        local max
        case $unit in
            m) max=525600;;
            h) max=8760;;
            d) max=365;;
        esac
        if (( ${#n} > ${#max} )) || { (( ${#n} == ${#max} )) && [[ "$n" > "$max" ]]; }; then
            die 'expiry exceeds the maximum supported lifetime of 365 days'
        fi
        case $unit in
            m) printf '%s\n' $((10#$n * 60));;
            h) printf '%s\n' $((10#$n * 3600));;
            d) printf '%s\n' $((10#$n * 86400));;
        esac
    else
        die "expiry must be a duration such as 30m, 1h, or 7d; got: $expiry"
    fi
}

expiry_timestamp() {
    local expiry=$1 seconds now
    seconds=$(expiry_seconds "$expiry")
    (( seconds == 0 )) && { printf '0\n'; return; }
    now=$(date +%s) || die 'could not read system clock'
    printf '%s\n' $((now + seconds))
}

upload() {
    local payload=$1 name=$2 content_type=${3:-application/octet-stream}
    local backend url size limit i
    local -a backends=( $(backend_list) )
    for i in "${!backends[@]}"; do
        backend=${backends[$i]}
        if [[ "$backend" == bobashare ]]; then limit=$BOBASHARE_MAX_UPLOAD; else limit=$QURL_MAX_UPLOAD; fi
        size=$(size_of "$payload")
        if (( size > limit )); then
            if (( i + 1 < ${#backends[@]} )); then
                printf '%s cannot carry this encrypted upload (%s > %s MiB); trying the next backend.\n' \
                    "$(backend_name "$backend")" "$(( (size + 1024*1024 - 1) / (1024*1024) ))" "$((limit / 1024 / 1024))" >&2
            else
                printf '%s cannot carry this encrypted upload (%s > %s MiB).\n' \
                    "$(backend_name "$backend")" "$(( (size + 1024*1024 - 1) / (1024*1024) ))" "$((limit / 1024 / 1024))" >&2
            fi
            continue
        fi
        printf 'Uploading via %s ...\n' "$(backend_name "$backend")" >&2
        if [[ "$backend" == bobashare ]]; then
            if url=$(upload_bobashare "$payload" "$name" "$content_type"); then
                printf '%s\n' "$url"
                return 0
            fi
        elif [[ "$backend" == qurl ]]; then
            if url=$(upload_qurl "$payload" "$name" "$content_type"); then
                printf '%s\n' "$url"
                return 0
            fi
        fi
        if (( i + 1 < ${#backends[@]} )); then
            printf '%s upload failed; trying the next backend.\n' "$(backend_name "$backend")" >&2
        else
            printf '%s upload failed.\n' "$(backend_name "$backend")" >&2
        fi
    done
    return 1
}

send_cmd() {
    local input=$1; shift
    parse_options "$@"
    validate_backend_expiry
    TMPDIR_DAVO=$(mktemp -d)
    set_password
    make_password_file
    local source="$input" source_zip="$TMPDIR_DAVO/archive.zip" payload="$TMPDIR_DAVO/archive.gpg" html="$TMPDIR_DAVO/davo.sh.html" size url name backend limit max_source created_at expires_at
    if [[ -d "$input" ]]; then
        zip_input "$input" "$source_zip"
        source="$source_zip"
        name="$(basename -- "$input").zip"
    else
        [[ -f "$input" ]] || die "not a regular file or directory: $input"
        size=$(size_of "$input")
        if (( size > ARCHIVE_THRESHOLD )); then
            zip_input "$input" "$source_zip"
            source="$source_zip"
            name="$(basename -- "$input").zip"
        else
            name=$(basename -- "$input")
        fi
    fi
    size=$(size_of "$source")
    if (( NO_HTML )); then
        max_source=0
        for backend in $(backend_list); do
            if [[ "$backend" == bobashare ]]; then limit=$BOBASHARE_MAX_UPLOAD; else limit=$QURL_MAX_UPLOAD; fi
            (( limit > max_source )) && max_source=$limit
        done
    else
        max_source=0
        for backend in $(backend_list); do
            if [[ "$backend" == bobashare ]]; then limit=$BOBASHARE_MAX_INPUT; else limit=$QURL_MAX_INPUT; fi
            (( limit > max_source )) && max_source=$limit
        done
    fi
    (( size <= max_source )) || die 'file is too large for the selected backends'
    printf 'Encrypting %s ...\n' "$name"
    gpg_encrypt "$source" "$payload"
    (( $(size_of "$payload") <= BOBASHARE_MAX_UPLOAD || $(size_of "$payload") <= QURL_MAX_UPLOAD )) || die 'encrypted payload is too large for the supported backends'
    if (( NO_HTML )); then
        url=$(upload "$payload" "${name}.gpg" 'application/octet-stream') || die 'all selected upload backends failed'
    else
        printf 'Packaging recipient HTML ...\n'
        created_at=$(date +%s) || die 'could not read system clock'
        expires_at=$(expiry_timestamp "$EXPIRY")
        render_html "$payload" "$name" "$html" "$created_at" "$expires_at"
        (( $(size_of "$html") <= BOBASHARE_MAX_UPLOAD || $(size_of "$html") <= QURL_MAX_UPLOAD )) || die 'recipient HTML is too large for the supported backends'
        url=$(upload "$html" "${name%.zip}.html" 'text/html; charset=utf-8') || die 'all selected upload backends failed'
    fi
    printf '\nPassword: %s\nURL: %s\n' "$DAVO_PASSWORD" "$url"
}

extract_html_payload() {
    local html=$1 out=$2
    python3 - "$html" "$out" <<'PY'
from pathlib import Path
import base64, json, re, sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
m = re.search(r"const DAVO_PAYLOAD_B64 = '([^']+)';", text)
f = re.search(r"const DAVO_FILENAME = (.*?);", text)
e = re.search(r"const DAVO_EXPIRES_AT = (\d+);", text)
if not m or not f or not e:
    raise SystemExit('not a davo.sh HTML artifact or missing payload metadata')
name = json.loads(f.group(1))
if not name or any(sep in name for sep in ('/', '\\')) or name in {'.', '..'}:
    raise SystemExit('invalid filename in davo.sh HTML artifact')
Path(sys.argv[2]).write_bytes(base64.b64decode(m.group(1), validate=True))
Path(sys.argv[2] + '.name').write_text(name, encoding='utf-8')
Path(sys.argv[2] + '.expires').write_text(e.group(1), encoding='ascii')
PY
}

get_cmd() {
    local url=$1; shift
    parse_options "$@"
    (( NO_HTML == 0 )) || die '--no-html is only valid with send'
    [[ "$BACKEND" == auto ]] || die '--backend is only valid with send'
    TMPDIR_DAVO=$(mktemp -d)
    set_password 1
    make_password_file
    local input="$TMPDIR_DAVO/input" payload="$TMPDIR_DAVO/payload.gpg" output http_code
    http_code=$(curl --silent --show-error --location --write-out '%{http_code}' -o "$input" "$url") || die 'download failed: could not reach the download server'
    if [[ "$http_code" == 404 ]]; then die 'download failed: the file was not found or has expired (HTTP 404)'; fi
    [[ "$http_code" =~ ^2[0-9][0-9]$ ]] || die "download failed: server returned HTTP $http_code"

    if extract_html_payload "$input" "$payload" >/dev/null 2>&1; then
        if [[ -s "$payload.expires" ]] && (( $(cat "$payload.expires") != 0 && $(date +%s) >= $(cat "$payload.expires") )); then
            die 'this davo.sh file has expired'
        fi
        output=${OUTPUT:-$(cat "$payload.name")}
    else
        cp -- "$input" "$payload"
        output=${OUTPUT:-davo.sh-recovered}
    fi
    [[ -n "$output" ]] || output=davo.sh-recovered
    if [[ -z "$OUTPUT" && -e "$output" ]]; then output="davo.sh-recovered.$(basename -- "$output")"; fi
    check_output "$output"
    printf 'Decrypting ...\n'
    gpg_decrypt "$payload" "$output"
    printf 'Recovered: %s\n' "$output"
}

encrypt_cmd() {
    local input=$1; shift
    [[ -f "$input" ]] || die 'encrypt accepts a regular file; use send for directories'
    parse_options "$@"
    (( NO_HTML == 0 )) || die '--no-html is only valid with send'
    [[ "$BACKEND" == auto ]] || die '--backend is only valid with send'
    TMPDIR_DAVO=$(mktemp -d)
    set_password
    make_password_file
    local output=${OUTPUT:-${input%.*}.gpg}
    check_output "$output"
    gpg_encrypt "$input" "$output"
    printf 'Created: %s\n' "$output"
}

decrypt_cmd() {
    local input=$1; shift
    [[ -f "$input" ]] || die "not a regular file: $input"
    parse_options "$@"
    (( NO_HTML == 0 )) || die '--no-html is only valid with send'
    [[ "$BACKEND" == auto ]] || die '--backend is only valid with send'
    TMPDIR_DAVO=$(mktemp -d)
    set_password
    make_password_file
    local output=${OUTPUT:-${input%.gpg}.recovered}
    check_output "$output"
    gpg_decrypt "$input" "$output"
    printf 'Recovered: %s\n' "$output"
}

main() {
    need openssl
    need gpg
    need curl
    need python3
    need zip
    case "${1:-}" in
        -h|--help) usage;;
        --version|version) printf 'davo.sh %s\n' "$VERSION";;
        send) (($# >= 2)) || die 'send requires a file or directory'; send_cmd "$2" "${@:3}";;
        get) (($# >= 2)) || die 'get requires a URL'; get_cmd "$2" "${@:3}";;
        encrypt) (($# >= 2)) || die 'encrypt requires a file'; encrypt_cmd "$2" "${@:3}";;
        decrypt) (($# >= 2)) || die 'decrypt requires a file'; decrypt_cmd "$2" "${@:3}";;
        *) usage; exit 1;;
    esac
}
main "$@"
