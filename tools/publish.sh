#!/usr/bin/env bash
# Publish a Lumenex Vibe APK on an update channel. Every projector on that channel sees it at its next check
# (at app start, then every 6 h).
#
#   bash tools/publish.sh <channel> <apk> [--min <versionCode>] [--rollout <0..100>] [--notes "<text>"] [--dry-run]
#
#   --min      projectors below this versionCode MUST update (no "Later"). Default: keep the channel's current one.
#   --rollout  share of projectors offered an optional update (mandatory ignores it). Default 100.
#   --notes    shown on the projector's update screen.
#   --dry-run  check everything, upload nothing.
#
# Refuses: another package; an APK not signed with the channel's key (production = the Lumenex release key); a
# debuggable APK on production; a versionCode below the one the channel already offers (projectors cannot go back).
# Order: the APK is uploaded and read back from its public URL first, the manifest last, so a projector never sees a
# manifest pointing at an APK that is not there yet.
set -euo pipefail

REPO=lumenexx/vibe-updates
PACKAGE=com.lumenex.tv
RELEASE_CERT=36fe7f3ae3040bdef8df784c0ac8ff9e871bf0a2e0e88aa7be61526344b6210f   # CN=Lumenex Vibe, 2026-11-05
STAGING_CERT=33cb17e33f03b9fc12b9bc63bbb2c4807fdd21981ee746299a9d63c00ba01330   # staging debug key
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "publish: $*" >&2; exit 1; }
say() { echo "== $*"; }

[ $# -ge 2 ] || die "usage: publish.sh <channel> <apk> [--min N] [--rollout P] [--notes TEXT] [--dry-run]"
CHANNEL="$1"; APK="$2"; shift 2
MIN=""; ROLLOUT=100; NOTES=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min) MIN="$2"; shift 2 ;;
    --rollout) ROLLOUT="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[[ "$CHANNEL" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || die "channel must be lower-case letters, digits, dashes"
[ -f "$APK" ] || die "no file $APK"
[[ "$ROLLOUT" =~ ^[0-9]+$ ]] && [ "$ROLLOUT" -le 100 ] || die "--rollout must be 0..100"
[ -z "$MIN" ] || [[ "$MIN" =~ ^[0-9]+$ ]] || die "--min must be a whole number"
command -v jq >/dev/null || die "jq is needed"
command -v gh >/dev/null || die "gh is needed"

say "What the APK is"
INFO="$(python3 -I "$HERE/apkinfo.py" "$APK")" || die "cannot read $APK"
echo "$INFO"
PKG="$(jq -r .package <<<"$INFO")"; CODE="$(jq -r .versionCode <<<"$INFO")"; NAME="$(jq -r .versionName <<<"$INFO")"
DEBUGGABLE="$(jq -r .debuggable <<<"$INFO")"; SIGNER="$(jq -r .signerSha256 <<<"$INFO")"
SUM="$(jq -r .sha256 <<<"$INFO")"; SIZE="$(jq -r .size <<<"$INFO")"
[ "$PKG" = "$PACKAGE" ] || die "the APK is $PKG, not $PACKAGE"
[[ "$CODE" =~ ^[0-9]+$ ]] || die "no versionCode in the APK"
case "$CHANNEL" in
  staging) WANT="$STAGING_CERT" ;;
  *) WANT="$RELEASE_CERT" ;;
esac
[ "$SIGNER" = "$WANT" ] || die "the APK is signed by $SIGNER; channel $CHANNEL needs $WANT"
if [ "$CHANNEL" = production ] && [ "$DEBUGGABLE" = true ]; then die "a debuggable APK never goes to production"; fi

say "What channel $CHANNEL offers now"
CUR="$(gh release download "$CHANNEL" -R "$REPO" -p update.json -O - 2>/dev/null || true)"
CUR_CODE=0; CUR_MIN=0
if [ -n "$CUR" ]; then
  CUR_CODE="$(jq -r '.versionCode // 0' <<<"$CUR")"; CUR_MIN="$(jq -r '.minVersionCode // 0' <<<"$CUR")"
  echo "versionCode $CUR_CODE, minVersionCode $CUR_MIN"
else
  echo "nothing yet"
fi
[ "$CODE" -ge "$CUR_CODE" ] || die "versionCode $CODE is below the $CUR_CODE the channel offers: projectors cannot go back"
MIN="${MIN:-$CUR_MIN}"
[ "$MIN" -le "$CODE" ] || die "--min $MIN is above the APK's versionCode $CODE"

ASSET="lumenex-vibe-$CHANNEL-$CODE.apk"
URL="https://github.com/$REPO/releases/download/$CHANNEL/$ASSET"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
jq -n --arg pkg "$PACKAGE" --arg ch "$CHANNEL" --argjson code "$CODE" --arg name "$NAME" --argjson min "$MIN" \
  --argjson rollout "$ROLLOUT" --arg url "$URL" --arg sum "$SUM" --argjson size "$SIZE" --arg signer "$SIGNER" \
  --arg notes "$NOTES" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema: 1, packageName: $pkg, channel: $ch, versionCode: $code, versionName: $name, minVersionCode: $min,
    rolloutPercent: $rollout, apkUrl: $url, sha256: $sum, size: $size, signerSha256: $signer, notes: $notes,
    publishedAt: $at}' > "$WORK/update.json"
say "The manifest"
cat "$WORK/update.json"
if [ "$DRY" = 1 ]; then say "dry run: nothing uploaded"; exit 0; fi

if ! gh release view "$CHANNEL" -R "$REPO" >/dev/null 2>&1; then
  say "Creating release $CHANNEL"
  gh release create "$CHANNEL" -R "$REPO" --title "Channel: $CHANNEL" --latest=false \
    --notes "Update channel \`$CHANNEL\` of the Lumenex Vibe app. Projectors read update.json from here; see README." >/dev/null
fi
cp "$APK" "$WORK/$ASSET"
say "Uploading $ASSET"
gh release upload "$CHANNEL" -R "$REPO" --clobber "$WORK/$ASSET"
say "Reading the APK back from $URL"
GOT="$(curl -sfL --retry 3 "$URL" | sha256sum | cut -d' ' -f1)"
[ "$GOT" = "$SUM" ] || die "the public APK reads $GOT, not $SUM: manifest NOT published"
say "Publishing update.json"
gh release upload "$CHANNEL" -R "$REPO" --clobber "$WORK/update.json"
LIVE="$(curl -sfL --retry 3 "https://github.com/$REPO/releases/download/$CHANNEL/update.json")"
[ "$(jq -r .versionCode <<<"$LIVE")" = "$CODE" ] || die "the public update.json does not read versionCode $CODE yet"
say "Done: channel $CHANNEL offers $NAME ($CODE), minimum $MIN, rollout $ROLLOUT %"
