# Building WireGuardKit against the VMPGuard engine

This branch points `WireGuardKitGo` at the [VMPGuard](https://github.com/avianit/VMPGuard)
fork of wireguard-go instead of upstream.

## What was on this branch before

`Sources/WireGuardKitGo/go.mod` required:

```
golang.zx2c4.com/wireguard v0.0.0-20230209153558-1e2c3e5a3c14
```

That pseudo-version is upstream commit **`1e2c3e5a3c14`, from February 2023** —
the engine *before* `6a84778` converted `conn` and `device` to the batched vector
API. VMPGuard's `UPSTREAM.md` records that commit as **19.2 % faster on
Darwin/arm64** than the commit VMPGuard is based on.

**So the app has been shipping the fast pre-vector engine.** Adopting VMPGuard
means taking on that 19.2 % regression and getting Darwin batching in exchange.
Whether that trade is positive is not a hypothetical question about this app — it
is the only question. `vmpbench` arm D versus arm B measures exactly it.

Do not ship this branch until that comparison has been run.

## How the Go code reaches the app

```
Sources/WireGuardKitGo/go.mod      →  which engine
        ↓ Makefile, go build -buildmode c-archive
out/libwg-go.a
        ↓ xcodebuild -create-xcframework
libwg-go.xcframework               →  committed to this repo
        ↓ Package.swift .binaryTarget
WireGuardKitGo (Swift target, compiles only dummy.c)
        ↓
WireGuardKit  →  your NetworkExtension
```

**`Package.swift` consumes a prebuilt binary target.** The `WireGuardKitGo` Swift
target compiles nothing but `dummy.c`; all the real code arrives through
`libwg-go.xcframework`. Editing `go.mod` therefore changes *nothing that ships*
until the framework is rebuilt and committed. This is the single easiest way to
convince yourself a change is live when it isn't.

## Rebuilding

```sh
Sources/WireGuardKitGo/build-xcframework.sh
git add Sources/WireGuardKitGo/libwg-go.xcframework
```

The script rebuilds the archive for `ios-arm64`, reassembles the xcframework, and
**fails if `internal/xnu.RecvmsgX` is not present in the result** — the batching
code being silently absent is the failure mode worth guarding, because it would
show up only as a fill rate of 1.00 on a device.

It builds through the Makefile rather than calling `go build`, because the
Makefile applies `goruntime-boottime-over-monotonic.diff` to a private copy of
GOROOT. That patch keeps Go's monotonic clock running while the device is
asleep; without it, timers inside a suspended NetworkExtension drift. It applies
cleanly to Go 1.25.2.

It also deletes the archives before building. The Makefile's only prerequisites
are `go.mod` and the patched GOROOT — it has no idea the engine sources changed
behind the `replace` directive, so without that it prints "Nothing to be done"
and ships the previous library.

## Pointing at a different engine

Right now `go.mod` carries a **local path** replace:

```
replace golang.zx2c4.com/wireguard => /Users/avianbrand/Desktop/Projects/VMPGuard
```

Good for iterating — edit the engine, run the script, test — but it only works on
that machine. For CI or anyone else, push VMPGuard and pin it:

```sh
cd Sources/WireGuardKitGo
go mod edit -replace=golang.zx2c4.com/wireguard=github.com/avianit/VMPGuard@<tag-or-commit>
GOFLAGS=-mod=mod go mod tidy
./build-xcframework.sh
```

Note that VMPGuard's `go.mod` still declares `module golang.zx2c4.com/wireguard`.
That is deliberate — it keeps the fork drop-in compatible, and it is why `replace`
is needed rather than a plain `require` of the GitHub path.

To go back to upstream, drop the replace and `go mod tidy`.

## Other required changes

- **`go 1.17` → `go 1.23.1`.** VMPGuard declares `go 1.23.1`, and since Go 1.21 a
  module may not require a dependency with a higher `go` directive than its own.
- **Dependency bumps**, applied by `go mod tidy`: `x/sys` 0.5.0 → 0.32.0,
  `x/crypto` 0.6.0 → 0.37.0, `x/net` 0.6.0 → 0.39.0.
- **gvisor is not pulled in.** VMPGuard requires it for `tun/netstack`, but
  `api-apple.go` imports only `conn`, `device` and `tun`, so it never compiles.

## Verified

- Compiles for `GOOS=ios GOARCH=arm64` with `-buildmode c-archive`.
- `GOOS=ios` satisfies the `//go:build darwin` constraint, so the batch path is
  genuinely linked in — `internal/xnu.RecvmsgX`, `SendmsgX`, the assembly
  trampolines and `conn.readBatchDarwin` are all present in the archive.
- The runtime patch applies to Go 1.25.2.
- The xcframework keeps its previous shape: one `ios-arm64` slice, no simulator
  and no macOS slice, matching what was committed before.

**Not verified: this has never run on a device.** It links; nothing here says it
holds a tunnel up.

## Two things to settle before shipping

**1. The NetworkExtension memory cap.** A packet-tunnel provider gets roughly
50 MB. VMPGuard requests batches of 16 datagrams instead of 1, which multiplies
the in-flight buffer count. This is the one change here that could plausibly get
the extension killed, and it will not show up on a desktop.

**2. There is no fill-rate reporter in this build.** VMPGuard's `batchstats.go`
lives in `package main` of the wireguard-go *command*, not the library, so it is
not part of the c-archive. `conn.BatchStats()` and `tun.BatchStats()` are exported
and callable — but nothing calls them here.

Without that, there is no way to tell on a device whether batching engaged at
all, and a fill rate of 1.00 means every other number is measuring something
else. Adding a periodic reporter to `api-apple.go`, routed through the existing
logger callback, is a small change and should come before any on-device
measurement.
