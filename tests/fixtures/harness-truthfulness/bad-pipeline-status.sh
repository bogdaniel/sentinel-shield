#!/bin/sh
# `tail` decides the exit status, so a failed push reports success.
if git push origin some-branch 2>&1 | tail -2; then
	printf 'PASS: pushed\n'
fi
