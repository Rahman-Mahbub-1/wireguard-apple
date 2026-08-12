#!/bin/bash
# Rebuild libwg-go.xcframework from whatever wireguard-go go.mod currently points at.
#
# This step is not optional. Package.swift consumes the Go code as a
# *binaryTarget* — the WireGuardKitGo Swift target compiles only dummy.c, and
# everything real comes from the prebuilt libwg-go.xcframework in this directory.
# Editing go.mod alone changes nothing that ships; the framework has to be rebuilt
# and committed, or the app keeps running the engine that was baked in last time.
set -euo pipefail
cd "$(dirname "$0")"

MIN_IOS="${MIN_IOS:-15.0}"   # matches Package.swift's .iOS("15.0")

echo "==> engine: $(go list -m -f '{{.Path}} {{if .Replace}}=> {{.Replace.Path}} {{.Replace.Version}}{{else}}{{.Version}}{{end}}' golang.zx2c4.com/wireguard)"

# The Makefile copies GOROOT and applies goruntime-boottime-over-monotonic.diff,
# which makes Go's monotonic clock keep counting while the device is asleep.
# Without it, timers inside a suspended NetworkExtension drift — so build through
# the Makefile rather than calling `go build` directly.
echo "==> building libwg-go.a for ios-arm64"
# The Makefile's only prerequisites are go.mod and the patched GOROOT — it does
# not know about the wireguard-go sources behind the replace directive. Editing
# the engine and re-running would otherwise print "Nothing to be done" and ship a
# stale library. Drop the archives so the build always happens; the patched
# GOROOT is left alone because recreating it means rsyncing all of Go.
rm -f out/libwg-go.a .tmp/wireguard-go-bridge/libwg-go-*.a
GOFLAGS=-mod=mod make build PLATFORM_NAME=iphoneos ARCHS=arm64

echo "==> assembling xcframework"
rm -rf .xcf-headers && mkdir -p .xcf-headers && cp wireguard.h .xcf-headers/
rm -rf libwg-go.xcframework
xcodebuild -create-xcframework \
  -library out/libwg-go.a \
  -headers .xcf-headers \
  -output libwg-go.xcframework >/dev/null
rm -rf .xcf-headers

echo "==> verifying the Darwin batch path is actually linked in"
# GOOS=ios satisfies the `darwin` build constraint, but a stale archive or a
# constraint mistake would silently ship the unbatched engine. Fail loudly here
# rather than discovering it from a fill rate of 1.00 on a device.
# grep -c rather than -q: under `set -o pipefail`, grep -q exits at the first
# match, nm dies of SIGPIPE, and the pipeline reports failure on success.
if [ "$(nm libwg-go.xcframework/ios-arm64/libwg-go.a 2>/dev/null | grep -c 'internal/xnu.RecvmsgX')" -gt 0 ]; then
  echo "    ok: internal/xnu.RecvmsgX present"
else
  echo "    !! internal/xnu.RecvmsgX MISSING — this build has no Darwin batching"
  exit 1
fi

echo
echo "built: $(du -h libwg-go.xcframework/ios-arm64/libwg-go.a | cut -f1)  $(lipo -info libwg-go.xcframework/ios-arm64/libwg-go.a)"
echo "commit libwg-go.xcframework/ for the change to reach the app."
