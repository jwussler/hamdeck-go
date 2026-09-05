#!/usr/bin/env bash
# Publish a release to PUBLIC GitHub. Nothing else ever pushes there.
#
# ⚠️ GITHUB IS A PUBLISH TARGET, NOT THE ORIGIN. Day to day this repo pushes to
# git.wa0o.com and nowhere else: development happens in private and the public
# history shows releases, not every experiment. That is the whole reason the
# local origin exists, so this is the ONLY script allowed to push to `public`.
#
# ⚠️ AND IT IS NOT A BACKUP. Between releases GitHub can be weeks behind. The
# backup is /opt/docker/forgejo/backup.sh - shack, then the NAS, then S3.
#
#   tools/release.sh v0.8.0 "what changed"
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: release.sh <tag> [message]}"
MSG="${2:-Release $TAG}"

case "$TAG" in v*) ;; *) echo "a tag looks like v1.2.3, not $TAG" >&2; exit 1 ;; esac

# ⚠️ REFUSE ON A DIRTY TREE. A release built from uncommitted work cannot be
# rebuilt from its own tag, and nobody finds that out until they try.
if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty - commit or stash before cutting a release" >&2
    git status --short >&2
    exit 1
fi

# ⚠️ AND REFUSE TO MOVE A TAG THAT EXISTS. A tag that has already been built
# against is a promise about what that build contained; moving it makes every
# artifact carrying that version a lie. Cut the next number instead.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists - cut the next number rather than moving it" >&2
    exit 1
fi

echo "== what this release will publish that GitHub does not have:"
git fetch -q public 2>/dev/null || true
git log --oneline public/main..HEAD 2>/dev/null | sed 's/^/   /' || echo "   (no public/main yet - first publish)"
echo
read -r -p "publish the above to PUBLIC GitHub as $TAG? [y/N] " ok
[ "$ok" = "y" ] || { echo "nothing published"; exit 1; }

git tag -a "$TAG" -m "$MSG"
git push origin main --tags          # the private origin first, always
git push public main --tags          # then the world
echo
echo "published $TAG to github.com/jwussler/hamdeck-go"
echo "CI there builds the installers; the local runner has already checked every commit."
