#!/bin/sh
# Install what scripts/ci/lint.sh needs, at the newest versions that have been
# public for at least COOLDOWN_DAYS, never anything newer (PER-159).
#
#   scripts/ci/install_lint_tools.sh <prefix>
#
# CI runs it on every job; the workbench runs it daily (lint-tools-refresh
# timer). Both resolve "newest before the cutoff", so the builder and CI land
# on the same versions without a pin anyone has to bump, and nothing reaches
# either until it has been public long enough for a bad release to be pulled.
#
# Each run builds a fresh venv at <prefix>/<UTC timestamp> and then points
# <prefix>/current at it. Fresh, because an upgrade in place never moves back:
# the cutoff alone decides every version. The previous build is kept, so a
# lint that is running during the swap still has its venv.
#
# What goes in, all under one cutoff:
#   pip         the newest release before the cutoff, picked from PyPI's upload
#               dates (the venv's own pip may predate --uploaded-prior-to)
#   ansible, ansible-lint
#               pip --uploaded-prior-to, which covers every dependency it
#               resolves too. The `ansible` package carries the collections
#               ansible-lint resolves, so ansible-galaxy (no cooldown) is not
#               needed.
#   ShellCheck  the newest GitHub release published before the cutoff, checked
#               against the sha256 GitHub publishes for the asset
#
# Linux x86_64 only (CI, the workbench); the laptop gets these from brew.
# Needs python3 with venv, curl, jq, tar, sha256sum and GNU date. GITHUB_TOKEN,
# if set, authenticates the one GitHub API call (CI runners share IPs and would
# hit the anonymous rate limit).

set -eu

COOLDOWN_DAYS=20

PREFIX=${1:?usage: install_lint_tools.sh <prefix>}

die() { echo "install_lint_tools: $*" >&2; exit 1; }

# pip's "a new release is available, upgrade" notice invites the one thing the
# cooldown is for not doing.
PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_DISABLE_PIP_VERSION_CHECK

now=$(date -u +%s)
CUTOFF=$(date -u -d "@$((now - COOLDOWN_DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)
BUILD="$PREFIX/$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)"
echo "cooldown ${COOLDOWN_DAYS} days: nothing published after $CUTOFF"

mkdir -p "$PREFIX"
# Two runs in the same second would share a build dir, and the cleanup below
# would then delete the build `current` points at.
[ ! -e "$BUILD" ] || die "$BUILD already exists; another run is in progress"
trap 'rm -rf "$BUILD"' EXIT
python3 -m venv "$BUILD"
PIP="$BUILD/bin/pip"

# ── pip ──────────────────────────────────────────────────────────────────
# Final releases only, every file uploaded before the cutoff and none yanked.
pip_version=$(curl -fsS https://pypi.org/pypi/pip/json | jq -r --arg c "$CUTOFF" '
    .releases | to_entries[]
    | select(.value | length > 0)
    | select(all(.value[]; .upload_time_iso_8601 < $c and (.yanked | not)))
    | .key' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[ -n "$pip_version" ] || die "no pip release before $CUTOFF"
"$PIP" install --quiet "pip==$pip_version"
"$PIP" install --help | grep -q -- --uploaded-prior-to ||
    die "pip $pip_version (newest before the cutoff) has no --uploaded-prior-to"

# ── ansible + ansible-lint ───────────────────────────────────────────────
"$PIP" install --quiet --uploaded-prior-to "$CUTOFF" ansible ansible-lint

# ── shellcheck ───────────────────────────────────────────────────────────
github() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/$1"
    else
        curl -fsS "https://api.github.com/$1"
    fi
}
release=$(github 'repos/koalaman/shellcheck/releases?per_page=30' | jq -c --arg c "$CUTOFF" '
    [.[] | select((.draft | not) and (.prerelease | not)
                  and (.tag_name | test("^v[0-9]")) and .published_at < $c)]
    | sort_by(.published_at) | last // empty')
tag=$(printf '%s' "$release" | jq -r '.tag_name // empty')
[ -n "$tag" ] || die "no shellcheck release before $CUTOFF"
asset="shellcheck-$tag.linux.x86_64.tar.gz"
url=$(printf '%s' "$release" | jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url')
digest=$(printf '%s' "$release" | jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // empty' | sed -n 's/^sha256://p')
[ -n "$url" ] || die "shellcheck $tag has no asset $asset"
[ -n "$digest" ] || die "GitHub publishes no sha256 for $asset; refusing an unverified binary"
curl -fsSL -o "$BUILD/shellcheck.tar.gz" "$url"
echo "$digest  $BUILD/shellcheck.tar.gz" | sha256sum -c - >/dev/null 2>&1 ||
    die "sha256 mismatch for $asset"
tar -xzf "$BUILD/shellcheck.tar.gz" -C "$BUILD"
install -m 0755 "$BUILD/shellcheck-$tag/shellcheck" "$BUILD/bin/shellcheck"
rm -rf "$BUILD/shellcheck.tar.gz" "$BUILD/shellcheck-$tag"

# ── swap in, keep one previous build ─────────────────────────────────────
ln -sfn "$(basename "$BUILD")" "$PREFIX/current"
trap - EXIT
builds=$(find "$PREFIX" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*Z' | sort)
count=$(printf '%s\n' "$builds" | grep -c . || true)
if [ "$count" -gt 2 ]; then
    printf '%s\n' "$builds" | head -n $((count - 2)) | while IFS= read -r old; do rm -rf "$old"; done
fi

echo "pip $pip_version"
"$BUILD/bin/shellcheck" --version | sed -n 's/^version: /shellcheck /p'
"$BUILD/bin/ansible-lint" --version 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*m//g' | head -n 1
