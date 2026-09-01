Status: needs-info

Blocked by: 02

# 03: Move lib-pi-05 to kernel 6.18.42

`lib-pi-05` runs `6.18.10-current-bcm2711`. `lib-pi-02` already runs
`6.18.42-current-bcm2711`, so it is a known-good build for this fleet and the
upgrade path is already proven on a node you own.

If the used-bit-read hypothesis is right, this is where a fix would land, since the
TXUBR restart path lives in `macb_main.c`. Whether 6.18.42 actually contains such a
fix is unverified — that is why this is `needs-info` rather than `ready-for-agent`.

## Scope

1. **First, check whether it is worth doing.** Diff `drivers/net/ethernet/cadence/`
   between 6.18.10 and 6.18.42. If nothing touched the TX path, this ticket is a
   general hygiene upgrade rather than a candidate fix, and should be re-triaged
   accordingly.
2. Upgrade and reboot.
3. Confirm `end0` still comes up, and that whatever ticket 02 set is still in force
   after the kernel change. An offload setting applied through a `.link` file should
   survive, but the point of 02's persistence requirement is that this gets checked
   rather than assumed.

## Acceptance criteria

- `uname -r` reports 6.18.42 or later.
- `ethtool -k end0` still shows 02's settings.
- `net_recorder` is running and writing samples after the reboot.
- No TX stall for 7 days, measured the same way as 02.

## Interaction with other tickets

Must not overlap 02's observation window. If 02 has already produced 7 clean days,
this becomes an ordinary upgrade and the clock restarts for its own window.
