#!/usr/bin/env bash
# Publishes the version in VERSION as a GitHub release and adds it to the
# Sparkle appcast.
#
#   scripts/release.sh [--notes "Texte des notes"]
#
# 1. Checks: clean tree, HEAD pushed, tag free, token and signing key present.
# 2. Builds Multitool.app (scripts/build-app.sh), zips it, signs the zip (EdDSA).
# 3. Creates the release vX.Y.Z on mmengual/multitool with the zip as asset.
# 4. Adds the version on top of appcast.xml, on the orphan branch "releases".
#
# Installed copies read the appcast at
# https://raw.githubusercontent.com/mmengual/multitool/releases/appcast.xml
# and download the asset through api.github.com, with the token embedded in the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="mmengual/multitool"
BRANCH="releases"
REMOTE="$(git remote get-url origin)"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
NOTES=""

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
log()  { printf '==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3, got: $VERSION"

# --- Checks -------------------------------------------------------------------
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes: commit them first, the release must match a commit."
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || fail "HEAD is not pushed to origin."
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "release $TAG already exists: bump VERSION."
fi
if [[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" != "PUBLIC" ]]; then
    security find-generic-password -s multitool-update-token -w >/dev/null 2>&1 \
        || fail "private repo and no update token in the keychain (item multitool-update-token). See README, section Mises à jour."
fi
[[ -x "$SPARKLE_BIN/sign_update" ]] || swift package resolve

# --- Build, zip, sign -------------------------------------------------------------
log "Building $VERSION…"
./scripts/build-app.sh >/dev/null
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Multitool.app/Contents/Info.plist)"

mkdir -p dist
ZIP="dist/Multitool-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent Multitool.app "$ZIP"
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" --account multitool "$ZIP")"
[[ "$SIGNATURE_ATTRS" == *edSignature* ]] || fail "sign_update failed: $SIGNATURE_ATTRS"
log "Signed $ZIP (build $BUILD)"

if [[ -z "$NOTES" ]]; then
    PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    RANGE="${PREVIOUS:+$PREVIOUS..}HEAD"
    NOTES="$(git log --pretty='- %s' "$RANGE" | head -20)"
fi

# --- GitHub release ------------------------------------------------------------------
log "Creating release $TAG…"
gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Multitool $VERSION" --notes "$NOTES" >/dev/null
git fetch -q --tags origin
ASSET_ID="$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name == \"$(basename "$ZIP")\") | .id")"
[[ -n "$ASSET_ID" ]] || fail "asset not found on release $TAG."
ASSET_URL="https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID"

# --- Appcast -------------------------------------------------------------------
log "Updating the appcast on branch $BRANCH…"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/multitool-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    git clone -q --depth 1 --branch "$BRANCH" "$REMOTE" "$WORK"
else
    git init -q "$WORK"
    git -C "$WORK" symbolic-ref HEAD "refs/heads/$BRANCH"
    git -C "$WORK" remote add origin "$REMOTE"
fi

VERSION="$VERSION" BUILD="$BUILD" ASSET_URL="$ASSET_URL" SIGNATURE_ATTRS="$SIGNATURE_ATTRS" \
NOTES="$NOTES" APPCAST="$WORK/appcast.xml" /usr/bin/python3 - <<'PY'
import html, os, re
from email.utils import formatdate

path = os.environ["APPCAST"]
header = ('<?xml version="1.0" encoding="utf-8"?>\n'
          '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
          '  <channel>\n    <title>Multitool</title>\n')
footer = '  </channel>\n</rss>\n'
items = []
if os.path.exists(path):
    items = re.findall(r"    <item>.*?</item>\n", open(path, encoding="utf-8").read(), re.S)

lines = [l[2:] if l.startswith("- ") else l for l in os.environ["NOTES"].splitlines() if l.strip()]
notes = "<ul>" + "".join(f"<li>{html.escape(l)}</li>" for l in lines) + "</ul>"
item = (
    "    <item>\n"
    f"      <title>Multitool {os.environ['VERSION']}</title>\n"
    f"      <pubDate>{formatdate(usegmt=True)}</pubDate>\n"
    f"      <sparkle:version>{os.environ['BUILD']}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{os.environ['VERSION']}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>\n"
    f"      <description><![CDATA[{notes}]]></description>\n"
    f"      <enclosure url=\"{os.environ['ASSET_URL']}\" type=\"application/octet-stream\" "
    f"{os.environ['SIGNATURE_ATTRS'].strip()}/>\n"
    "    </item>\n"
)
with open(path, "w", encoding="utf-8") as f:
    f.write(header + item + "".join(items[:9]) + footer)
PY

git -C "$WORK" add appcast.xml
git -C "$WORK" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -q -m "Appcast: Multitool $VERSION (build $BUILD)"
git -C "$WORK" push -q origin "HEAD:refs/heads/$BRANCH"

log "Published Multitool $VERSION (build $BUILD)."
echo "    Release: https://github.com/$REPO/releases/tag/$TAG"
echo "    Appcast: https://raw.githubusercontent.com/$REPO/$BRANCH/appcast.xml"
