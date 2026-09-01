Status: needs-triage

Blocked by: 02

# 04: Auto-recover a stalled TX path

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
