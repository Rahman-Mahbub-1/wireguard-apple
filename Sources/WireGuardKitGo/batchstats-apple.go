/* SPDX-License-Identifier: MIT
 *
 * VMPGuard: batched-syscall fill rate, reported from inside a NetworkExtension.
 */

// The one number that decides whether Darwin batching is worth shipping is the
// achieved fill rate: how many datagrams a single recvmsg_x actually returns.
// Batching amortises a syscall across the datagrams already queued behind it, so
// at a fill of 1.0 nothing was amortised and any speed difference came from
// somewhere else. Five separate desktop setups measured 1.7-2.8; nobody has ever
// measured it on a phone.
//
// VMPGuard has a reporter for this, but it lives in package main of the
// wireguard-go *command* and so is absent from the c-archive this library builds
// into. conn.BatchStats and tun.BatchStats are exported and callable — until
// this file, nothing called them, and a device could have been running the
// unbatched path with no way to notice.
//
// Deliberately opt-in. A NetworkExtension has a tight memory and CPU budget and
// this has no business running in a shipping build unless someone asked for it.
// Call wgEnableBatchStats from Swift, e.g. behind a debug setting.
//
// Requires the VMPGuard engine; upstream wireguard-go exports neither counter.
package main

import "C"

import (
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

//export wgEnableBatchStats
//
// Report batch fill rates every `seconds` through the tunnel's existing logger,
// so the lines arrive wherever the app already sends WireGuard logs. Returns 0
// on success, -1 for an unknown handle. Stops on its own when the tunnel goes
// down. Calling it twice on one tunnel starts two reporters; don't.
func wgEnableBatchStats(handle int32, seconds int32) int32 {
	h, ok := tunnelHandles[handle]
	if !ok {
		return -1
	}
	if seconds < 1 {
		seconds = 5
	}
	go reportBatchStats(h.Device, h.Logger, time.Duration(seconds)*time.Second)
	return 0
}

func reportBatchStats(dev *device.Device, logger *device.Logger, interval time.Duration) {
	// Device.Wait closes when the tunnel goes down, which is what stops this
	// goroutine. A NetworkExtension may bring tunnels up and down repeatedly in
	// one process lifetime, and a reporter per dead tunnel would accumulate.
	done := dev.Wait()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var lUC, lUP, lUR, lTRC, lTRF, lTWC, lTWF uint64
	rate := func(n, d uint64) float64 {
		if d == 0 {
			return 0
		}
		return float64(n) / float64(d)
	}

	logger.Verbosef("batch stats: reporting every %s", interval)
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
		}

		uc, up, ur := conn.BatchStats()
		trc, trf, twc, twf := tun.BatchStats()
		if uc == 0 && trc == 0 && twc == 0 {
			// Not a measurement of zero: either the platform has no batched path,
			// the runtime probe declined, or nothing has moved yet. Printing a row
			// of zeros here would read as data.
			logger.Verbosef("batch stats: batching inactive (no batched calls recorded)")
			continue
		}

		// Interval deltas, not lifetime totals. An idle tunnel sends keepalives at
		// a fill of 1.0, and on a phone there is a great deal of idle — cumulative
		// figures drift toward 1.0 and read as "batching did nothing" regardless of
		// what happened under load.
		dUC, dUP, dUR := uc-lUC, up-lUP, ur-lUR
		dTRC, dTRF := trc-lTRC, trf-lTRF
		dTWC, dTWF := twc-lTWC, twf-lTWF
		lUC, lUP, lUR, lTRC, lTRF, lTWC, lTWF = uc, up, ur, trc, trf, twc, twf

		// Read and write are reported separately because they are fed by different
		// sources and measure very differently: TUN reads by the phone's outbound
		// traffic, TUN writes by whatever one UDP receive returned.
		logger.Verbosef(
			"batch stats: UDP-rx %.2f pkts/call (%.1f req, %.0f%% used) over %d | "+
				"TUN-rd %.2f frames/call over %d | TUN-wr %.2f frames/call over %d | "+
				"cumulative UDP-rx %.2f, TUN-rd %.2f, TUN-wr %.2f",
			rate(dUP, dUC), rate(dUR, dUC), 100*rate(dUP, dUR), dUC,
			rate(dTRF, dTRC), dTRC,
			rate(dTWF, dTWC), dTWC,
			rate(up, uc), rate(trf, trc), rate(twf, twc),
		)
	}
}
