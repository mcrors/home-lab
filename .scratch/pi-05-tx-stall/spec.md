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

> **Superseded 2026-09-06.** The cause is known upstream and it is not the
> used-bit-read race reasoned toward below. The TSTART doorbell write is a posted
> MMIO write that can be dropped in the PCIe fabric between the RP1 and the SoC, so
> the MAC never starts the TX DMA. See the 2026-09-06 update at the bottom. This
> section is kept because the observations in it are sound and only the mechanism
> drawn from them was wrong.


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

**Confidence.** The correlation with the Pi 5 and `macb` is solid. The transmit
engine parking is now directly observed (ticket 01, 2026-09-01 17:42 stall): the
MAC's transmit descriptor pointer sits frozen at one address while the receive
pointer keeps advancing. Why it parks is still unproven, and used-bit-read remains
a candidate rather than a finding.

**One step of the reasoning above is wrong and is kept for the record.** Point 2,
the argument from `NETDEV WATCHDOG` staying silent, concluded that the driver kept
reclaiming descriptors as sent. The capture shows it did not — the driver's own
counter froze alongside the hardware's, so the ring was not draining and the
kernel watchdog should have fired. It did not, across four minutes.

**That silence was explained on 2026-09-06 and is not a second defect.**
`netdev_watchdog_up()` returns immediately when the driver has no `ndo_tx_timeout`,
and `macb` in 6.18.10 had none, so the transmit watchdog timer was never armed on
this node. The queue state was never in question. Ticket 03 carries the detail.

## Decisions recorded

- **Change one thing at a time.** At five stalls per 52 hours a fix declares itself
  within days, so there is no reason to bundle changes and lose attribution.
- **Instrument before mitigating.** If the TSO change works there is never another
  stall to confirm the mechanism on, and if it fails the next stall should already
  be captured in full. Ticket 01 goes first for that reason.
- **Auto-recovery goes last.** *Withdrawn 2026-09-06.* It assumed the measure is
  reboots. `net_recorder` records stall onset and a `TX_RESUMED` line separately, so
  frequency stays measurable with recovery active. Ticket 04 carries the detail.
- **Persist offload settings through the role, never `ethtool -K` by hand.** This
  node reboots itself every few hours; a live-only setting would silently vanish at
  the first stall and the experiment would read as a false negative. The role is
  gone, but the reasoning applies to any future per-node network setting here.
- **Measure by `stall.log`, not by reboots.** *Added 2026-09-06.* Now that the
  kernel recovers from a stall without rebooting, reboot count no longer tracks
  fault frequency and would read a working recovery as a fixed bug.

## Out of scope

- Fixing the driver upstream. Already reported and understood there; the root-cause
  patches exist and were reverted on 2026-07-14, so this is a matter of waiting for
  the vendor branch rather than anything to file.
- Widening `net_recorder` to other nodes. Nothing else runs `macb`.
- The watchdog behaviour around these stalls. Tracked in `node-hardening`.

## Tickets

| # | Title | Status | Blocked by |
| --- | --- | --- | --- |
| 01 | Capture MAC registers on TX stall | resolved | — |
| 02 | Disable TSO on `end0` (scatter-gather deferred) | resolved (negative) | — |
| 03 | Move lib-pi-05 to a kernel with the macb TX recovery path | resolved | 02 |
| 04 | Auto-recover a stalled TX path | wontfix (superseded by 03) | 02 |

All four are closed. The project is now a waiting game on upstream, described in
the 2026-09-06 update below.

## Update 2026-09-05 — TSO disabled, project paused

> **Superseded by the 2026-09-06 update below.** The "what a future reader should do
> first" instruction at the end of this section is stale: the question it poses was
> answered on 2026-09-06, TSO was not the trigger, and the scatter-gather escalation
> it points to was never run and is no longer wanted. The stall history table is
> still accurate.


`infra/roles/nic_offload` applied to lib-pi-05 at 10:20. TSO and GSO are off and
verified in force; scatter-gather is deliberately still on. Ticket 02 carries the
detail.

**Full stall history now recorded**, seven in total:

| Onset | Ended | Captured |
| --- | --- | --- |
| Aug 30 ~20:07 | watchdog reboot | no |
| Aug 30 ~20:27 | watchdog reboot | no |
| Aug 31 ~15:27 | watchdog reboot | no |
| Aug 31 ~18:17 | watchdog reboot | no |
| Sep 01 ~00:15 | watchdog reboot | samples only |
| Sep 01 17:42 | watchdog reboot | 4 snapshots |
| Sep 01 23:56 | watchdog reboot | 4 snapshots |

**No stall has ever recovered on its own.** `net_recorder` writes a `TX_RESUMED`
line when transmission restarts without a reboot, and across the whole recording
period there is not one. The fault latches; it does not flicker. This also rules
out brief self-healing stalls happening unnoticed between the visible ones.

**The node then went quiet unaided** from Sep 1 23:56 to the change on Sep 5, a
gap about four times its previous worst. Whatever governs the frequency is not
understood, and it is the main threat to interpreting ticket 02's result. Hence
the 2-3 week window rather than one.

**What a future reader should do first:** check whether lib-pi-05 has stalled
since 2026-09-05. `sudo grep -c "TX STALL SNAPSHOT" /var/log/net-recorder/stall.log*`
on the node, remembering the rotated files. No stalls means ticket 02 is holding
and the answer is "TSO was the trigger". Any stall means move to the
scatter-gather escalation, and ticket 02 explains why that needs a new ticket.

**Known gap, unfixed:** the rotating packet capture does not survive a reboot.
`tcpdump -W` restarts numbering at file 0 on every start and the 5MB rotation
never triggers at this traffic level, so the pre-stall capture is always the file
overwritten on the way back up. Never blocked anything so far, since the counters
and registers proved sufficient.

## Update 2026-09-06 — root cause identified upstream, kernel 6.18.44 deployed

### Ticket 02 failed and TSO is ruled out

lib-pi-05 stalled again at 07:05:13 with TSO and GSO confirmed off, and was rebooted
by the watchdog at 07:09:55. The setting was genuinely in force, so this is a real
negative. The stall was indistinguishable from the two captured on 2026-09-01. That
is the eighth recorded stall.

`infra/roles/nic_offload` and its playbook have been removed and TSO, GSO and
scatter-gather are all back on. Ticket 02 carries the evidence and two mechanical
traps found during the rollback.

### The cause

The Cadence GEM in the RP1 sits behind PCIe. The TSTART doorbell write to the NCR
register is a **posted** MMIO write that can be dropped or delayed in the PCIe
fabric, so the MAC never starts the TX DMA. Documented in `raspberrypi/linux`
PR #7340 and at https://dtype.org/wiki/Cm5_macb_network_hang. The published
signature matches ours exactly: TX frozen, RX and interrupts continuing, carrier up,
all error counters at zero.

This also explains the fleet-to-fleet disagreement about workarounds. Disabling EEE,
TSO and GSO with enlarged rings helped the Talos fleet in
`siderolabs/sbc-raspberrypi` issue 91 and failed on the CM5 fleet in the dtype
writeup, which is the result we got. None of them touch the doorbell write, so
whether they help is incidental.

EEE is not supported on this interface, so that published workaround does not apply
here at all. Rings are at the 512/512 default against an 8192/4096 maximum and were
left alone.

### What was deployed, and what it does and does not do

lib-pi-05 now runs `6.18.44-current-bcm2711` (Armbian 26.8.3), which registers an
`ndo_tx_timeout` callback in `macb`. The kernel's transmit watchdog notices a
stopped queue and calls `macb_tx_restart`.

**This is recovery, not prevention.** The three patches that address the root cause
were reverted from `rpi-6.18.y` on 2026-07-14. Stalls will continue. They should now
clear in about 5 seconds instead of costing 4.5 minutes and a reboot.

Note that `/etc/armbian-release` still reports 26.2.1, because only the kernel
packages were upgraded. lib-pi-05 and lib-pi-02 will report different Armbian
versions while running comparable kernels. That is expected.

### What to check next

The next stall is the test. Expect all three of:

- a `NETDEV WATCHDOG` line in the kernel log,
- a `TX_RESUMED` line in `samples.log`, the first one ever recorded,
- no new entry in `journalctl --list-boots`.

If instead the node dies for 4.5 minutes and reboots as before, `dev_watchdog` is
not firing, which would mean `trans_start` is being refreshed during the stall.
Ticket 04 is then back on the table and ticket 03's Answer records why.

Stall frequency stays measurable either way, since `stall.log` still gets a full
snapshot at onset. Recovery does not cost the diagnosis.

### The remaining fix is upstream and out of our hands

Watch for the posted-write flush and ISR re-check patches returning to `rpi-6.18.y`.
Until they land, this node has a hardware-triggered fault that it papers over
quickly. That is the end state for now, and it is an acceptable one.
