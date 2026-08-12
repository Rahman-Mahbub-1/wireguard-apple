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

`go.mod` pins the engine by commit:

```
replace golang.zx2c4.com/wireguard => github.com/avianit/VMPGuard v0.0.0-20260811121619-cb9c8f7f4482
```

VMPGuard's `go.mod` still declares `module golang.zx2c4.com/wireguard`. That is
deliberate — it keeps the fork drop-in compatible, and it is why `replace` is
needed rather than a plain `require` of the GitHub path.

**VMPGuard is a private repository**, so the Go module proxy and checksum
database cannot see it. Without `GOPRIVATE` a build fails with a 404 from
`sum.golang.org` and a git credential prompt:

```sh
export GOPRIVATE='github.com/avianit/*'
```

`build-xcframework.sh` sets this itself. CI needs it too, plus a token with read
access to the repo.

To move to a newer engine commit:

```sh
cd Sources/WireGuardKitGo
go mod edit -replace=golang.zx2c4.com/wireguard=github.com/avianit/VMPGuard@<commit>
GOFLAGS=-mod=mod go mod tidy
./build-xcframework.sh
```

For local iteration, point it at a working copy instead — nothing else changes:

```sh
go mod edit -replace=golang.zx2c4.com/wireguard=/path/to/VMPGuard
```

To go back to upstream, drop the replace and `go mod tidy`.

## Known limitation: no simulator slice

`libwg-go.xcframework` contains **`ios-arm64` only** — no simulator, no macOS.
Consuming this package via SwiftPM means any simulator build fails to link, which
also affects previews and some indexing. Device builds are unaffected. Adding the
missing slices is a change to `build-xcframework.sh`, not to the engine.

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

**2. Nothing is measured unless you turn the reporter on** — see below.

## Measuring the fill rate on a device

VMPGuard's own `batchstats.go` lives in `package main` of the wireguard-go
*command*, so it is not part of this c-archive. `batchstats-apple.go` adds the
equivalent for the library, reporting through the tunnel's existing logger so the
lines land wherever the app already sends WireGuard logs.

**It is opt-in and off by default.** From the app, before starting the tunnel:

```swift
WireGuardAdapter.batchStatsInterval = 5   // seconds; 0 disables
```

Then look for:

```
batch stats: UDP-rx 2.83 pkts/call (5.4 req, 52% used) over 41210 | TUN-rd 1.00 … | TUN-wr 2.83 …
```

**Read the fill first, before any throughput number.** Batching amortises one
syscall across the datagrams already queued behind it, so at a fill of 1.00
nothing was amortised and any speed difference measured beside it came from
somewhere else. Five desktop setups have measured 1.7–2.8; a phone has never been
measured. If iOS reports ~1.0, that is the answer and there is nothing further to
optimise here.

Figures are per-interval deltas rather than lifetime totals, because a phone
spends most of its time idle, keepalives run at a fill of 1.0, and cumulative
numbers drift toward "batching did nothing" no matter what happened under load.

The reporter stops itself when the tunnel goes down, so a NetworkExtension that
cycles tunnels does not accumulate goroutines. Leave the interval at 0 in a
shipping build.

Implementation notes: `batchstats-apple.go` is a separate file and `api-apple.go`
is untouched, so upstream changes to it rebase cleanly. The exported symbol is
`wgEnableBatchStats(handle, seconds)`, declared in `wireguard.h`. It compiles
only against the VMPGuard engine — upstream exports neither counter.
