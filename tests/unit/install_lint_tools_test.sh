#!/bin/sh
# Unit test for scripts/ci/install_lint_tools.sh — the 20-day cooldown that CI
# and the workbench install the lint toolchain under (PER-159).
#
#   tests/unit/install_lint_tools_test.sh
#
# PyPI, the GitHub API, the download and pip are stubs, with releases dated on
# both sides of the cutoff. Checks that only versions older than the cutoff are
# chosen (yanked and pre-releases skipped), that the cutoff reaches pip, that a
# ShellCheck build whose sha256 does not match or is not published is refused
# without touching the live build, and that old builds are pruned.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/ci/install_lint_tools.sh"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin" "$WORK/fix"
LOG="$WORK/log"
export LOG

printf '\n── Lint toolchain installer (20-day cooldown)\n'

# The script needs GNU date and sha256sum; macOS ships neither by default.
if ! date -d @0 >/dev/null 2>&1; then
    if command -v gdate >/dev/null 2>&1; then
        ln -s "$(command -v gdate)" "$WORK/bin/date"
    else
        printf '   - no GNU date (brew install coreutils); skipping\n   PASS\n'; exit 0
    fi
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$WORK/bin/sha256sum"
    chmod +x "$WORK/bin/sha256sum"
fi
PATH="$WORK/bin:$PATH"

now=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
OLD=$(iso $((now - 30 * 86400)))
OLDER=$(iso $((now - 60 * 86400)))
NEW=$(iso $((now - 5 * 86400)))
CUTOFF_DAY=$(date -u -d "@$((now - 20 * 86400))" +%Y-%m-%d)

# ── fixtures ─────────────────────────────────────────────────────────────
# pip: 25.0 is the answer. 26.1 is newer but yanked, 26.9 is inside the
# cooldown, 26.0rc1 is a pre-release.
cat > "$WORK/fix/pip.json" <<EOF
{"releases": {
  "25.0":    [{"upload_time_iso_8601": "$OLD", "yanked": false}],
  "26.1":    [{"upload_time_iso_8601": "$OLD", "yanked": true}],
  "26.0rc1": [{"upload_time_iso_8601": "$OLD", "yanked": false}],
  "26.9":    [{"upload_time_iso_8601": "$NEW", "yanked": false}]
}}
EOF

mkdir -p "$WORK/tar/shellcheck-v0.10.0"
printf '#!/bin/sh\necho "version: 0.10.0"\n' > "$WORK/tar/shellcheck-v0.10.0/shellcheck"
chmod +x "$WORK/tar/shellcheck-v0.10.0/shellcheck"
tar -czf "$WORK/fix/sc.tar.gz" -C "$WORK/tar" shellcheck-v0.10.0
GOOD=$(sha256sum "$WORK/fix/sc.tar.gz" | cut -d' ' -f1)

# releases <digest field for v0.10.0>: v0.10.0 is the answer. v0.11.0 is inside
# the cooldown, "latest" is a pre-release, v0.9.0 is older.
releases() {
    asset() { printf '{"name": "shellcheck-%s.linux.x86_64.tar.gz", "browser_download_url": "https://example.invalid/%s.tar.gz"%s}' "$1" "$1" "$2"; }
    cat > "$WORK/fix/releases.json" <<EOF
[
  {"tag_name": "v0.11.0", "draft": false, "prerelease": false, "published_at": "$NEW",
   "assets": [$(asset v0.11.0 ', "digest": "sha256:aaaa"')]},
  {"tag_name": "latest", "draft": false, "prerelease": true, "published_at": "$OLD",
   "assets": [$(asset latest ', "digest": "sha256:bbbb"')]},
  {"tag_name": "v0.10.0", "draft": false, "prerelease": false, "published_at": "$OLD",
   "assets": [$(asset v0.10.0 "$1")]},
  {"tag_name": "v0.9.0", "draft": false, "prerelease": false, "published_at": "$OLDER",
   "assets": [$(asset v0.9.0 ', "digest": "sha256:cccc"')]}
]
EOF
}

# ── stubs ────────────────────────────────────────────────────────────────
cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
out=""; auth=no; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out=\$2; shift ;;
        -H) case "\$2" in Authorization:*) auth=yes ;; esac; shift ;;
        -*) ;;
        *) url=\$1 ;;
    esac
    shift
done
echo "curl \$url auth=\$auth" >> "\$LOG"
case "\$url" in
    https://pypi.org/pypi/pip/json) cat "$WORK/fix/pip.json" ;;
    https://api.github.com/*) cat "$WORK/fix/releases.json" ;;
    https://example.invalid/v0.10.0.tar.gz) cp "$WORK/fix/sc.tar.gz" "\$out" ;;
    *) exit 22 ;;
esac
EOF

# python3 -m venv DIR: a venv whose pip logs its arguments. NO_FLAG makes it a
# pip that predates --uploaded-prior-to.
cat > "$WORK/bin/python3" <<'EOF'
#!/bin/sh
[ "$1" = -m ] && [ "$2" = venv ] || exit 1
mkdir -p "$3/bin"
cat > "$3/bin/pip" <<'PIP'
#!/bin/sh
echo "pip $*" >> "$LOG"
case " $* " in
    *" --help "*) [ -n "${NO_FLAG:-}" ] || echo "  --uploaded-prior-to <datetime_or_duration>" ;;
    *" ansible-lint"*) printf '#!/bin/sh\necho "ansible-lint 1.0.0"\n' > "$(dirname "$0")/ansible-lint"
                       chmod +x "$(dirname "$0")/ansible-lint" ;;
esac
PIP
chmod +x "$3/bin/pip"
EOF
chmod +x "$WORK/bin/curl" "$WORK/bin/python3"

P="$WORK/prefix"
# run [VAR=value ...]: through env, because a VAR=value prefix on a shell
# function outlives the call in some shells (bash in POSIX mode).
run() { : > "$LOG"; env "$@" sh "$SCRIPT" "$P" > "$WORK/out" 2>&1; }
builds() { find "$P" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*Z' | wc -l | tr -d ' '; }

# ── a good run ───────────────────────────────────────────────────────────
releases ", \"digest\": \"sha256:$GOOD\""
if run; then pass "installs with every pick older than the cutoff"; else fail "good run failed: $(cat "$WORK/out")"; fi

if grep -q "^pip install --quiet pip==25.0$" "$LOG"; then
    pass "pip: newest final release before the cutoff (skips yanked 26.1, rc, 26.9)"
else
    fail "pip pick: $(grep 'pip==' "$LOG")"
fi
if grep -q "^pip install --quiet --uploaded-prior-to ${CUTOFF_DAY}T[0-9:]*Z ansible ansible-lint$" "$LOG"; then
    pass "ansible and ansible-lint resolved with --uploaded-prior-to the 20-day cutoff"
else
    fail "pip cutoff: $(grep 'ansible' "$LOG")"
fi
if [ "$("$P/current/bin/shellcheck" 2>/dev/null)" = "version: 0.10.0" ]; then
    pass "shellcheck: newest release before the cutoff (skips v0.11.0 and the pre-release)"
else
    fail "shellcheck pick: $(find "$P" 2>&1 | head -20)"
fi
if grep -q "auth=no" "$LOG" && ! grep -q "auth=yes" "$LOG"; then
    pass "no token, no Authorization header"
else
    fail "auth: $(grep api.github "$LOG")"
fi
live=$(readlink "$P/current")

# ── refused downloads leave the live build alone ─────────────────────────
sleep 1
releases ', "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
if ! run && grep -q "sha256 mismatch" "$WORK/out" && [ "$(readlink "$P/current")" = "$live" ] && [ "$(builds)" = 1 ]; then
    pass "a sha256 mismatch is refused; current and the build dirs are untouched"
else
    fail "mismatch: rc/out=$(cat "$WORK/out"), current=$(readlink "$P/current"), builds=$(builds)"
fi

sleep 1
releases ''
if ! run && grep -q "publishes no sha256" "$WORK/out" && [ "$(readlink "$P/current")" = "$live" ]; then
    pass "a release with no published sha256 is refused"
else
    fail "no digest: $(cat "$WORK/out")"
fi

sleep 1
releases ", \"digest\": \"sha256:$GOOD\""
if ! run NO_FLAG=1 && grep -q "has no --uploaded-prior-to" "$WORK/out"; then
    pass "a pip without --uploaded-prior-to stops the install instead of skipping the cooldown"
else
    fail "no flag: $(cat "$WORK/out")"
fi

# ── token and pruning ────────────────────────────────────────────────────
sleep 1
if run GITHUB_TOKEN=t && grep -q "api.github.com.* auth=yes" "$LOG"; then
    pass "GITHUB_TOKEN authenticates the GitHub API call"
else
    fail "token: $(grep api.github "$LOG")"
fi
sleep 1
run
if [ "$(builds)" = 2 ] && [ -x "$P/current/bin/shellcheck" ] && [ "$(readlink "$P/current")" != "$live" ]; then
    pass "keeps the current and one previous build, prunes the rest"
else
    fail "prune: builds=$(builds), current=$(readlink "$P/current")"
fi

if [ "$failures" -eq 0 ]; then
    printf '   PASS\n'
    exit 0
fi
printf '   FAIL (%d)\n' "$failures"
exit 1
