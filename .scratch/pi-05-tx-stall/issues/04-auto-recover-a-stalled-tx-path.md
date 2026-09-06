Status: wontfix

Blocked by: 02

# 04: Auto-recover a stalled TX path

**Closed 2026-09-06, superseded by ticket 03. The kernel now does this in-driver.
See the Comments at the bottom.**

A mitigation rather than a fix. Deliberately last.

A stall currently costs ~4.5 minutes of node death plus a watchdog reboot plus pod
rescheduling. Bouncing `end0` re-initialises the TX ring and re-arms TSTART, which
is precisely the state the spec says needs clearing, and should turn that into a few
seconds.

The `net_recorder` role left this out on purpose when it was written, before the
mechanism was understood. It now has a specific justification rather than being a
guess, but the ordering argument against running it early still holds.

## Why it goes last

- It masks the symptom that 02 and 03 are measured by. Running it during either
  observation window destroys the experiment.
- It destroys the evidence for whatever the next theory turns out to be.
- If 02 holds, this may not be wanted at all. If 02 fails, this is what makes the
  node usable while the real fix is chased upstream.

## Open questions for triage

- **Trigger threshold.** Ticket 01 already counts consecutive zero-TX samples, so
  the counter exists. How many before bouncing? Too eager and it fires on ordinary
  quiet; too slow and the watchdog gets there first. The watchdog shuts down at
  `retry-timeout + interval` (~270s), which is the hard ceiling.
- **`ethtool -r` or `ip link set down/up`?** The first is less disruptive if the
  driver implements it. Whether `macb` does needs checking.
- **What happens to k3s and Longhorn across a bounce?** A few seconds of link loss
  is much gentler than the current reboot, but it is not free, and RWO volume
  attachments are already known to behave badly when a node goes away
  (`node-hardening` ticket 04).
- **Bound the retries.** A bounce that does not fix it must not loop. Fall through
  to the existing watchdog behaviour after N attempts.

## Acceptance criteria

- A stall is detected and recovered without the watchdog shutting the node down.
- `stall.log` still captures the full snapshot **before** the bounce. The recovery
  must not cost the diagnosis.
- `journalctl --list-boots` gains no entry for a recovered stall.
- A stall the bounce cannot fix still ends in the watchdog reboot, not a loop.

## Comments

### 2026-09-06 — superseded by the in-kernel recovery in 6.18.44

Ticket 03 moved lib-pi-05 to `6.18.44-current-bcm2711`, which registers an
`ndo_tx_timeout` callback in `macb`. The kernel's own transmit watchdog now notices
a stopped queue and calls `macb_tx_restart`. That is this ticket's goal, done in the
driver instead of a userspace link bounce, and it answers every open triage question
better than a bounce could:

- **Trigger threshold.** `dev_watchdog` fires on `watchdog_timeo`, in seconds,
  against the ~270s watchdog ceiling this ticket worried about. No counter tuning.
- **`ethtool -r` or `ip link set down/up`.** Neither. `macb_tx_restart` re-arms the
  transmit path without taking the link down at all.
- **What happens to k3s and Longhorn.** Nothing. There is no link loss to survive.
- **Bounded retries.** Not needed. If the restart does not work the existing
  watchdog daemon still reboots the node, which is the fall-through this ticket
  asked for.

The ordering argument in "Why it goes last" is also moot. It assumed a recovery
would mask the symptom that tickets 02 and 03 are measured by. That is only true
when the measure is reboots. `net_recorder` writes a `TX_STALL SNAPSHOT` on onset
and a `TX_RESUMED` line when transmission restarts without a reboot, so stall
frequency stays measurable with recovery active, and a recovered stall is now
directly observable rather than invisible.

**Reopen this only if** the next stall shows `dev_watchdog` not firing, which would
mean `trans_start` is being refreshed during the stall. In that case a userspace
detector is back on the table, and ticket 03's Answer records the residual risk.
