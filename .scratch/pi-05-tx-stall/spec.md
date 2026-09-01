Status: ready-for-human

# lib-pi-05 transmit stall

## Context

`lib-pi-05` loses the network every few hours, stays dead for ~4.5 minutes, and is
rebooted by the watchdog. Five occurrences in the 52 hours to 2026-09-01:

| Onset | Watchdog shutdown |
| --- | --- |
| Aug 30 ~20:07 | Aug 30 20:11 |
| Aug 30 ~20:27 | Aug 30 20:31 |
| Aug 31 ~15:27 | Aug 31 15:32 |
| Aug 31 ~18:17 | Aug 31 18:21 |
| Sep 01 ~00:15 | Sep 01 00:19 |

Earlier occurrences on 2026-08-22 and 2026-08-30 are recorded in the `net_recorder`
role's commit message (`6794597`). No other node has ever done this.

Every previous investigation ran on Prometheus data, which is scraped across the
network from `lib-pi-06` and therefore goes blind at the exact moment the fault
starts. Those rounds ruled out socket and fd leaks, conntrack exhaustion,
under-voltage and traffic spikes, and could get no further. The `net_recorder` role
(`6794597`) moved the recording onto the node itself to break that limit.

## The 2026-09-01 00:15 outage, recorded end to end

First outage captured by `net_recorder`. `samples.log` ran to 00:19:48, four seconds
before the watchdog shut the node down.

| time | d_rx_pkts | d_tx_pkts | d_retrans | gw_state |
| --- | --- | --- | --- | --- |
| 00:14:57 | 750 | 861 | 0 | REACHABLE |
| 00:15:07 | 303 | 260 | 12 | REACHABLE |
| 00:15:17 | 98 | **0** | 20 | STALE |
| 00:15:37 | 54 | **0** | 21 | INCOMPLETE |
| 00:16:07 | 40 | **0** | 606 | INCOMPLETE |
| 00:19:48 | 22 | **0** | 180 | DELAY |

`tx_pkts` froze at 3,147,813 and did not move again across 27 consecutive samples.
Reception kept working throughout.

This is a transmit stall. Every prior theory assumed a receive-side or link-side
fault, and the role's own interpretation notes were written for that case.

Supporting detail:

- **The link never dropped.** `carrier_changes` stayed at 1 (its boot value),
  `oper=up`, `speed=1000`, for the whole outage and every previous one.
- **Reception was alive but starved.** After the first 40 seconds
  `d_rx_bytes / d_rx_pkts` settles at 53-60 bytes, so all that was still arriving
  was minimum-size broadcast. Nothing that required us to have transmitted first
  ever came back.
- **The stack was trying.** `RetransSegs` reached 672 per 10s interval and the
  gateway ARP entry cycled STALE → DELAY → INCOMPLETE → FAILED.
- **Nothing reported an error.** `tx_errs`, `tx_drop`, `tx_carrier` all 0;
  `rx_errs` flat at 1237; `d_rx_errs` 0. No `ETHTOOL` delta line fired during the
  outage. The kernel log for that boot contains no `macb` or `end0` message and no
  `NETDEV WATCHDOG: transmit queue timed out`.

## Root cause hypothesis

**`lib-pi-05` is the only Raspberry Pi 5 in the fleet.**

| node | model | ethernet driver |
| --- | --- | --- |
| lib-pi-01 | Pi 4B | `bcmgenet` |
| lib-pi-02 | Pi 4B | `bcmgenet` |
| lib-pi-03 | Pi 4B | `bcmgenet` |
| lib-pi-04 | Pi 4B | `bcmgenet` |
| lib-pi-06 | Pi 4B | `bcmgenet` |
| **lib-pi-05** | **Pi 5B** | **`macb`** |

Pi 4 ethernet is Broadcom GENET on the SoC. Pi 5 ethernet is a Cadence GEM inside
the RP1 southbridge, driven by `macb`. Different silicon, different driver, no
shared code. The only node that fails is the only node running a different NIC.
That is why `lib-pi-01` and `lib-pi-03`, pinging the same gateway through the same
switch, never saw anything (recorded in `node-hardening` ticket 08).

Two facts narrow the mechanism:

1. **The MAC's own hardware counter froze.** For `macb`, `tx_packets` in
   `/proc/net/dev` is read from the MAC's `tx_frames` register, the same one
   `ethtool -S` reports. The MAC put nothing on the wire.
2. **`NETDEV WATCHDOG` never fired**, across 4.5 minutes. It trips when the driver
   has kept the TX queue stopped past `watchdog_timeo`, which is seconds. `end0`
   has one TX queue and a 512-descriptor ring; with TCP retransmitting at 600+
   segments per 10s the ring would have filled and stopped the queue almost
   immediately.

Together: the driver kept reclaiming TX descriptors as sent while the hardware
transmitted nothing.

That is the signature of the Cadence GEM's TX DMA halting on a **used-bit-read**.
The TX DMA reads a descriptor whose "used" bit is already set, treats it as
ring-empty, halts transmission and clears TSTART. The driver is meant to see
`TXUBR` and re-arm TSTART. If that restart is lost or races the completion path,
the hardware stays halted while the completion path keeps reclaiming descriptors as
sent. The ring drains, the queue never stops, the watchdog never fires, nothing
leaves.

Consistent with this, a register dump taken on the healthy node on 2026-09-01 shows
the TSR word at `0x21`, with the used-bit-read flag already latched. Used-bit-read
events occur routinely on this hardware and are normally recovered from.

This also explains why the earlier rounds found nothing: socket counts, fd counts,
conntrack, voltage and traffic volume all sit above or beside the descriptor ring.

**Confidence.** The correlation with the Pi 5 and `macb` is solid. The specific
used-bit-read mechanism is inferred from counter behaviour and has not been observed
directly; ticket 01 exists to observe it.

## Decisions recorded

- **Change one thing at a time.** At five stalls per 52 hours a fix declares itself
  within days, so there is no reason to bundle changes and lose attribution.
- **Instrument before mitigating.** If the TSO change works there is never another
  stall to confirm the mechanism on, and if it fails the next stall should already
  be captured in full. Ticket 01 goes first for that reason.
- **Auto-recovery goes last.** A link bounce masks the symptom that tickets 02 and
  03 are measured by, and destroys the evidence for whatever the next theory needs.
- **Persist offload settings through the role, never `ethtool -K` by hand.** This
  node reboots itself every few hours; a live-only setting would silently vanish at
  the first stall and the experiment would read as a false negative.

## Out of scope

- Fixing the driver upstream. If ticket 02 confirms the mechanism, that becomes a
  separate report to the Raspberry Pi kernel tree.
- Widening `net_recorder` to other nodes. Nothing else runs `macb`.
- The watchdog behaviour around these stalls. Tracked in `node-hardening`.

## Tickets

| # | Title | Status | Blocked by |
| --- | --- | --- | --- |
| 01 | Capture MAC registers on TX stall | needs-info | — |
| 02 | Disable TSO and scatter-gather on `end0` | ready-for-agent | 01 |
| 03 | Move lib-pi-05 to kernel 6.18.42 | needs-info | 02 |
| 04 | Auto-recover a stalled TX path | needs-triage | 02 |

Run 02 and 03 strictly in sequence. Running them together makes the result
unattributable, which is the entire reason they are separate tickets.
