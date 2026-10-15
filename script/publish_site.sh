#!/usr/bin/env bash
# Build the release app, wrap it in a .dmg, and publish site/ + the .dmg to Cloudflare Pages.
#   ./script/publish_site.sh             build, package and deploy
#   ./script/publish_site.sh --no-deploy build and package only; nothing leaves this Mac
# Cloudflare login is done in the browser by `wrangler login` (OAuth); no token is stored here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${ISLAND_PAGES_PROJECT:-agent-island}"
VERSION="$(tr -d '\n' < "$ROOT_DIR/VERSION")"
APP="$ROOT_DIR/dist/Release/Agent 灵动岛.app"
DMG_NAME="Agent-Island-$VERSION.dmg"
DMG="$ROOT_DIR/dist/Release/$DMG_NAME"
OUT="$ROOT_DIR/dist/site-deploy"
DEPLOY=1
[[ "${1:-}" == "--no-deploy" ]] && DEPLOY=0

echo "==> 1/4 Building release app $VERSION"
"$ROOT_DIR/script/build_and_run.sh" --release-package
bash "$ROOT_DIR/script/check_release.sh" "$APP"

echo "==> 2/4 Making $DMG_NAME"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Agent 灵动岛" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
codesign -dv "$DMG" 2>/dev/null || true
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "==> 3/4 Assembling the site"
rm -rf "$OUT"
mkdir -p "$OUT/media/icons" "$OUT/download"
cp "$ROOT_DIR/site/index.html" "$ROOT_DIR/site/style.css" "$ROOT_DIR/site/island.js" "$ROOT_DIR/site/analytics.js" "$ROOT_DIR/site/_worker.js" "$ROOT_DIR/site/_routes.json" "$ROOT_DIR/site/dashboard.html" "$OUT/"
# dashboard.html loads echarts from here, not a CDN: jsDelivr was unreachable on some
# networks and left every chart blank. Without this copy the dashboard ships broken.
cp "$ROOT_DIR/site/echarts.min.js" "$OUT/"
# Only files the page actually uses; the unused state-*.jpg stay private.
# og-card.jpg is referenced by absolute URL from the og:image/twitter:image tags, so it must
# ship even though nothing on the page loads it.
for f in app-icon.png favicon.png film-poster.jpg film.mp4 desktop-wallpaper.svg og-card.jpg; do
  cp "$ROOT_DIR/site/media/$f" "$OUT/media/"
done
cp "$ROOT_DIR/site/media/icons/"*.png "$OUT/media/icons/"
cp "$DMG" "$OUT/download/"
# Point the download buttons at the file that ships next to the page.
perl -0pi -e "s#dmgUrl: ''#dmgUrl: 'download/$DMG_NAME'#" "$OUT/index.html"
grep -q "dmgUrl: 'download/$DMG_NAME'" "$OUT/index.html"
echo "First-party website analytics: enabled via site/wrangler.jsonc"
cat > "$OUT/_headers" <<EOF
/download/*
  Content-Disposition: attachment
  Cache-Control: public, max-age=300
EOF
du -sh "$OUT"

if (( ! DEPLOY )); then
  echo "Done, not deployed. Site: $OUT  Installer: $DMG"
  exit 0
fi

echo "==> 4/4 Deploying to Cloudflare Pages ($PROJECT)"
wrangler whoami >/dev/null 2>&1 || wrangler login
wrangler pages project list 2>/dev/null | grep -qw "$PROJECT" \
  || wrangler pages project create "$PROJECT" --production-branch main
(cd "$ROOT_DIR/site" && wrangler pages deploy "$OUT" --project-name "$PROJECT" --branch main --commit-dirty=true)
