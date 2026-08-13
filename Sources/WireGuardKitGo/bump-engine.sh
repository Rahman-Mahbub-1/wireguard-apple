#!/bin/bash
# Point this package at a VMPGuard engine commit and rebuild what actually ships.
#
# Two things have to move together. go.mod records which engine commit to build,
# and libwg-go.xcframework is the prebuilt binary the app links against —
# Package.swift consumes the Go code as a binaryTarget, so bumping go.mod alone
# changes nothing that reaches a device. This script does both, in order.
#
#   ./bump-engine.sh                 # build whatever VMPGuard main is at now
#   ./bump-engine.sh v1.2.0          # a tag
#   ./bump-engine.sh cb9c8f7         # a specific commit
#   ./bump-engine.sh main --commit   # ...and commit the result
#   ./bump-engine.sh main --dry-run  # just say what would change
#
# Afterwards, in the app: File > Packages > Update to Latest Package Versions.
set -euo pipefail
cd "$(dirname "$0")"

ENGINE_MODULE="golang.zx2c4.com/wireguard"   # the path VMPGuard declares internally
ENGINE_REPO="github.com/avianit/VMPGuard"    # where it actually lives

REF="main"
COMMIT=0
DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --commit)  COMMIT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {print substr($0,3); next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)        echo "unknown flag: $arg" >&2; exit 1 ;;
    *)         REF="$arg" ;;
  esac
done

# VMPGuard is private, so the module proxy and checksum database cannot see it.
# Without this, go fails with a 404 from sum.golang.org. Fetching goes direct,
# using whatever credentials git already has (osxkeychain, here).
export GOPRIVATE="${GOPRIVATE:-github.com/avianit/*}"
export GOFLAGS="${GOFLAGS:--mod=mod}"

echo "==> resolving ${ENGINE_REPO}@${REF}"
before="$(go list -m -f '{{if .Replace}}{{.Replace.Version}}{{end}}' "$ENGINE_MODULE")"

# Resolve the ref to a pseudo-version before touching go.mod. `go get` cannot do
# this job: VMPGuard declares its module path as golang.zx2c4.com/wireguard, so
# `go get github.com/avianit/VMPGuard@main` dies on a path mismatch. The engine
# is only reachable through the replace directive, and `go mod edit` is purely
# textual — it would happily write the literal string "main" as a version.
version="$(go list -m -f '{{.Version}}' "${ENGINE_REPO}@${REF}")"

echo "    was: ${before:-<unset>}"
echo "    now: ${version}"

if [ "$before" = "$version" ] && [ "$FORCE" -eq 0 ]; then
  echo
  echo "Already pinned to ${version}."
  echo "Pass --force to rebuild the xcframework against it anyway."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry run — go.mod untouched, nothing built."
  exit 0
fi

echo "==> rewriting the replace directive"
go mod edit -replace "${ENGINE_MODULE}=${ENGINE_REPO}@${version}"
go mod tidy

# The real work: patches GOROOT so Go's monotonic clock survives device sleep,
# cross-compiles for ios/arm64, assembles the xcframework, and refuses to finish
# if the Darwin batch path is missing from the archive.
echo "==> rebuilding the xcframework"
./build-xcframework.sh

cd ../..
echo
echo "==> changed"
git status --short -- Sources/WireGuardKitGo/go.mod \
                      Sources/WireGuardKitGo/go.sum \
                      Sources/WireGuardKitGo/libwg-go.xcframework

if [ "$COMMIT" -eq 1 ]; then
  git add Sources/WireGuardKitGo/go.mod \
          Sources/WireGuardKitGo/go.sum \
          Sources/WireGuardKitGo/libwg-go.xcframework
  if git diff --cached --quiet; then
    echo "Nothing changed — the rebuild was byte-identical. No commit made."
    exit 0
  fi
  git commit -m "Build the engine at ${version}" \
             -m "Was ${before:-<unset>}. Rebuilt libwg-go.xcframework so the change reaches the app."
  echo
  echo "Committed. Push when ready:  git push origin $(git rev-parse --abbrev-ref HEAD)"
else
  echo
  echo "Not committed. To ship it:"
  echo "  git add Sources/WireGuardKitGo/{go.mod,go.sum,libwg-go.xcframework}"
  echo "  git commit -m 'Build the engine at ${version}'"
  echo "  git push origin $(git rev-parse --abbrev-ref HEAD)"
fi
