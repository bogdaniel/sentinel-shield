#!/bin/sh
# BROKEN FIXTURE: the pipeline reports tail's status, so a failed command reads as success.
#
# INERT BY CONSTRUCTION: `git` is shadowed by a local function, so executing this fixture
# contacts no remote, touches no repository, and writes nothing. The pipeline/status-capture
# shape under test is preserved exactly.
git() { printf "simulated failure\n" >&2; return 1; }
if git push origin some-branch 2>&1 | tail -2; then
	printf "PASS: pushed\n"
fi
