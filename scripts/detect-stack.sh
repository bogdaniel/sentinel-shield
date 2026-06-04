#!/bin/sh
# Sentinel Shield — detect the stack(s) of a project.
# POSIX sh. Prints detected stacks to stdout, one per line, and a summary.
set -eu

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
	echo "error: target directory '$TARGET' not found" >&2
	exit 1
fi

# Space-separated list of detected stacks (avoids non-portable echo -e / literal \n).
DETECTED=""

add() {
	DETECTED="${DETECTED} $1"
	echo "detected: $1"
}

# --- PHP frameworks ---
if [ -f "$TARGET/artisan" ]; then
	add "laravel"
elif [ -f "$TARGET/symfony.lock" ] || [ -f "$TARGET/bin/console" ]; then
	add "symfony"
elif [ -f "$TARGET/composer.json" ]; then
	add "php"
fi

# --- Node / React ---
if [ -f "$TARGET/package.json" ]; then
	add "node"
	# React detection: dependency in package.json or a vite/react config present.
	if grep -q '"react"' "$TARGET/package.json" 2>/dev/null; then
		add "react"
	elif ls "$TARGET"/vite.config.* >/dev/null 2>&1; then
		add "react"
	fi
fi

# --- Docker ---
if [ -f "$TARGET/Dockerfile" ] || ls "$TARGET"/*.Dockerfile >/dev/null 2>&1; then
	add "docker"
elif [ -f "$TARGET/docker-compose.yml" ] || [ -f "$TARGET/compose.yaml" ]; then
	add "docker"
fi

# --- GitHub Actions ---
if [ -d "$TARGET/.github/workflows" ]; then
	add "github-actions"
fi

echo "----"
# Trim leading space for a clean summary.
DETECTED=$(echo "$DETECTED" | sed 's/^ *//')
if [ -z "$DETECTED" ]; then
	echo "No known stack detected in '$TARGET'."
	echo "Sentinel Shield supports: laravel, symfony, node, react, docker, github-actions."
else
	echo "Summary: detected in '$TARGET': $DETECTED"
fi
