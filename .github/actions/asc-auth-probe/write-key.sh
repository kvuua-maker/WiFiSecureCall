#!/bin/bash
# Writes the App Store Connect AuthKey to $KEY_PATH from the value in $PRIVATE_KEY.
#
# How that secret was pasted is out of our control: with real newlines, with escaped newlines, base64
# encoded, or wrapped in whatever the copy source added. Rather than trusting one guess about its
# shape, every plausible key body is collected and openssl decides which one is a real private key.
# Only openssl ever decides, and $KEY_PATH is written once, from a body re-verified against the scratch
# file, so the path the rest of a job signs with cannot disagree with the body that was selected.
#
# Both PRIVATE_KEY and KEY_PATH are read from the environment. The key and any token are never printed:
# the only shape reported is the length of the accepted body and the curve it decodes to.
set -euo pipefail

# The AuthKey .p8 arrives through a repository secret, so how it was pasted is out of our control: with
# real newlines, with escaped newlines, base64 encoded, or wrapped in whatever the copy source added.
# Rather than trusting one guess about its shape, this step collects every plausible key body it can
# find and asks openssl which one is a real private key. Trimming is tried too, because a paste that
# carried extra characters into the body still contains an intact key sitting next to them.
set -euo pipefail
umask 077
mkdir -p "$(dirname "$KEY_PATH")"
work="$(mktemp -d)"

# Escaped carriage returns are removed before escaped newlines, so a value pasted out of JSON or a
# Windows editor does not leave a literal backslash-r whose letter would end up inside the base64.
flat="$(printf '%s' "$PRIVATE_KEY" | sed -e 's/\\r//g' -e 's/\\n/\n/g' | LC_ALL=C tr -d '\t\r\n\357\273\277')"

candidates="$work/candidates"
: > "$candidates"

# Whatever sits between the first BEGIN marker and the first END marker.
if printf '%s' "$flat" | grep -q -- '-----BEGIN'; then
  inner="$(printf '%s' "$flat" \
    | sed -E -e 's/^.*\-{5}BEGIN[A-Z0-9 ]+\-{5}//' -e 's/\-{5}END[A-Z0-9 ]+\-{5}.*$//' \
    | LC_ALL=C tr -dc 'A-Za-z0-9+/=')"
  [ -z "$inner" ] || printf '%s\n' "$inner" >> "$candidates"
fi

# Every long run of base64 characters, longest first. This survives a missing marker, a duplicated one,
# and any text pasted before or after the key.
printf '%s' "$flat" \
  | grep -oE '[A-Za-z0-9+/=]{120,}' \
  | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2 \
  | head -5 >> "$candidates" || true

# The whole value as one base64 blob, which is what a deliberately encoded secret looks like.
if printf '%s' "$flat" | openssl base64 -d -A > "$work/blob" 2>/dev/null; then
  decoded="$(LC_ALL=C tr -d '\t\r\n' < "$work/blob")"
  if printf '%s' "$decoded" | grep -q -- '-----BEGIN'; then
    inner="$(printf '%s' "$decoded" \
      | sed -E -e 's/^.*\-{5}BEGIN[A-Z0-9 ]+\-{5}//' -e 's/\-{5}END[A-Z0-9 ]+\-{5}.*$//' \
      | LC_ALL=C tr -dc 'A-Za-z0-9+/=')"
    [ -z "$inner" ] || printf '%s\n' "$inner" >> "$candidates"
  else
    printf '%s' "$decoded" | grep -oE '[A-Za-z0-9+/=]{120,}' | head -5 >> "$candidates" || true
  fi
fi

# A candidate body is written out as PEM and judged by openssl. Nothing else decides what the key is.
# The locals matter: without them this function would overwrite the loop variable the caller reads its
# candidates from, and every attempt after the first would trim an already trimmed string.
#
# It writes the scratch file, never KEY_PATH. Writing the accepted key straight to KEY_PATH meant that
# any candidate examined after the accepted one overwrote it, so the path the rest of this job signs
# with could hold a rejected body while `match` still named the accepted one, and the declared-length
# trim below then compared one key's structure against another key's length.
probe="$work/probe.pem"
try_body() {
  local body="$1"
  [ "$(( ${#body} % 4 ))" -eq 0 ] || return 1
  {
    printf '%s\n' '-----BEGIN PRIVATE KEY-----'
    printf '%s' "$body" | fold -w 64
    printf '\n%s\n' '-----END PRIVATE KEY-----'
  } > "$probe"
  openssl pkey -in "$probe" -noout -check >/dev/null 2>&1
}

match=''
match_fp=''
ambiguous=0
# Whether two accepted bodies are the same key is decided by the key they decode to, not by
# comparing them as text. openssl accepts a body with extra characters at its end, so one key
# legitimately validates at more than one length, and comparing strings would call that
# ambiguity and refuse a perfectly good secret.
fingerprint_of() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null \
    | sed 's/^.*= //' || true
}
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  [ "$ambiguous" -eq 1 ] && continue
  size="${#candidate}"
  # Trimming is tried in order of how much is removed, so the smallest valid body wins and the written
  # file holds the key alone rather than the key plus whatever came with it. break 2 here only ends the
  # search over this candidate's own offsets; the next candidate is still examined, because a second
  # key in the same secret is something to refuse rather than to silently prefer.
  for total in $(seq 0 64); do
    length="$(( size - total ))"
    [ "$length" -ge 120 ] || break
    [ "$(( length % 4 ))" -eq 0 ] || continue
    for front in $(seq 0 "$total"); do
      back="$(( total - front ))"
      if try_body "${candidate:$front:$length}"; then
        body="${candidate:$front:$length}"
        accepted="$(fingerprint_of "$probe")"
        if [ -z "$match" ]; then
          match="$body"
          match_fp="$accepted"
        elif [ "$match_fp" != "$accepted" ]; then
          ambiguous=1
        fi
        break 2
      fi
    done
  done
done < "$candidates"

if [ "$ambiguous" -eq 1 ]; then
  echo '::error::APPSTORE_PRIVATE_KEY holds more than one different private key.'
  echo '::error::Nothing in the secret says which one is the AuthKey_<KEY_ID>.p8 for this key id, so there'
  echo '::error::is no basis for choosing and no file was written. Store only the contents of one file.'
  exit 1
fi

if [ -z "$match" ]; then
  # A passphrase protected key is a real and common mistake here: exporting from Keychain or from a
  # .p12 produces this header, and openssl would otherwise report it as an unreadable structure.
  if printf '%s' "$flat" | grep -q -- 'ENCRYPTED PRIVATE KEY'; then
    echo '::error::APPSTORE_PRIVATE_KEY is a password protected key (BEGIN ENCRYPTED PRIVATE KEY).'
    echo '::error::App Store Connect keys are not encrypted. Download AuthKey_<KEY_ID>.p8 again and store it as it is.'
    exit 1
  fi
  echo '::error::No private key could be read out of APPSTORE_PRIVATE_KEY.'
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    echo "::error::The longest body found was ${#candidate} base64 characters. A prime256v1 PKCS#8 body has 184."
    break
  done < "$candidates"
  echo '::error::APPSTORE_PRIVATE_KEY must hold only the contents of the AuthKey_<KEY_ID>.p8 downloaded from App Store Connect.'
  exit 1
fi

# openssl stops reading once the key structure is complete and ignores whatever follows it, so a body
# with extra characters at its end still validates. The body is cut back to the length the structure
# itself declares, which leaves only the key.
#
# The accepted body is written to the scratch file again first. After the loop the scratch file
# holds whichever candidate was tried last, which is not the accepted one whenever other
# candidates followed it, so reading the structure from it would describe the wrong key.
if ! try_body "$match"; then
  echo '::error::The accepted key body did not validate on its own, so no key file was written.'
  exit 1
fi
# `|| true` because asn1parse exits non-zero on a body it cannot read, and a failure here must be
# reported by the checks below rather than by a silent exit from set -e inside a substitution.
structure="$(openssl asn1parse -in "$probe" -inform PEM 2>/dev/null | head -1 || true)"
# asn1parse prints "hl=3 l= 135", so l= and its value are separate words. A space rather than \b is
# used to tell l= from the l inside hl=, because BSD grep on the macOS runner has no word boundary.
header_len="$(printf '%s' "$structure" | grep -oE 'hl= *[0-9]+' | grep -oE '[0-9]+' || true)"
content_len="$(printf '%s' "$structure" | grep -oE '(^| )l= *[0-9]+' | grep -oE '[0-9]+' || true)"
declared=$(( ${header_len:-0} + ${content_len:-0} ))
if [ -n "$declared" ] && [ "$declared" -gt 0 ]; then
  wanted=$(( (declared + 2) / 3 * 4 ))
  if [ "$wanted" -lt "${#match}" ] && [ "$wanted" -ge 120 ]; then
    if try_body "${match:0:$wanted}"; then
      match="${match:0:$wanted}"
    fi
  fi
fi

# The one and only write to KEY_PATH. It happens after the body has been accepted and after the
# declared-length trim, from a body re-verified against the scratch file, so the path the archive
# and the fingerprint sign with cannot disagree with the body that was selected.
if ! try_body "$match"; then
  echo '::error::The accepted key body stopped validating, so no key file was written.'
  exit 1
fi
cp "$probe" "$KEY_PATH"

# App Store Connect only ever issues EC prime256v1 keys, and the requests it signs are ES256 JWTs. A key
# of any other type is one xcodebuild would reject much later, and with a far less obvious message.
curve="$(openssl pkey -in "$KEY_PATH" -noout -text 2>/dev/null | grep -m1 -E 'ASN1 OID|NIST CURVE' || true)"
case "$curve" in
  *prime256v1*|*P-256*) ;;
  *)
    echo "::error::The key must be the EC prime256v1 key App Store Connect issues, but this one is: ${curve:-not an EC key}"
    exit 1
    ;;
esac

chmod 600 "$KEY_PATH"
rm -rf "$work"
echo "The API key is a valid prime256v1 private key (${#match} base64 characters)."
