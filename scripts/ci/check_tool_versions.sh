#!/bin/sh
# Fail unless the lint tools on PATH are the versions scripts/ci/tool-versions.conf
# pins. lint.sh runs this first, so CI, the builder and the laptop either agree
# on the toolchain or say loudly that they do not (PER-159).
#
#   scripts/ci/check_tool_versions.sh [tool-versions.conf]

set -u

FILE=${1:-$(dirname -- "$0")/tool-versions.conf}
[ -r "$FILE" ] || { echo "cannot read $FILE"; exit 1; }

pinned() { sed -n "s/^$1=//p" "$FILE"; }

# ansible-lint colours its --version output even when piped; strip the escapes
# before reading the number.
strip_ansi() { tr -d '\033' | sed 's/\[[0-9;]*m//g'; }

rc=0
check() {
    tool=$1 want=$2 have=$3
    if [ -z "$want" ]; then
        echo "$tool: no pinned version in $FILE"; rc=1
    elif [ -z "$have" ]; then
        echo "$tool: not found on PATH (pinned $want)"; rc=1
    elif [ "$have" != "$want" ]; then
        echo "$tool: $have on PATH, $FILE pins $want"; rc=1
    else
        echo "$tool $have"
    fi
}

have_shellcheck=$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p')
have_ansible_lint=$(ansible-lint --version 2>/dev/null | strip_ansi | sed -n 's/^ansible-lint \([^ ]*\).*/\1/p' | head -n 1)

check shellcheck "$(pinned SHELLCHECK_VERSION)" "$have_shellcheck"
check ansible-lint "$(pinned ANSIBLE_LINT_VERSION)" "$have_ansible_lint"

exit "$rc"
