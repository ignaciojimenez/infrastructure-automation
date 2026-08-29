#!/bin/sh
# TEMPORARY — deliberately breaks shellcheck to force a red main, so the
# #home-alerts step added in 5e2e5f6 can be proven to actually post. Reverted
# in the very next commit. See docs/TODO.md item 25.
#
# Not named *_test.sh on purpose: tests/run_unit_tests.sh globs unit/*_test.sh,
# and this must not join the unit suite. It only needs to match the shellcheck
# glob tests/*.sh.
probe=$(echo probe)
if [ $? -eq 0 ]; then # SC2181, deliberate — this is the violation
    echo "$probe"
fi
