Status: needs-info

# 01: Capture MAC registers on TX stall

Implemented and deployed 2026-09-01. Open until a real stall produces a snapshot.

`samples.log` can show that the MAC stopped transmitting. It cannot show why. The
spec's used-bit-read hypothesis is inferred from counter behaviour and needs direct
observation of the MAC to confirm or kill it.

This ticket goes before 02 and 03 because of what happens either way afterwards: if
disabling TSO works, there is never another stall to confirm the mechanism on, and
if it does not work, the next stall should already be captured in full. Deploying
this afterwards learns nothing in the good case and costs a cycle in the bad one.

## What was built

`net_recorder` counts consecutive samples where `d_tx_pkts` is exactly `0`. On the
second (~10s into a stall) it writes a snapshot to a new `stall.log`, then backs off
exponentially. A real 27-sample episode yields snapshots at zero-TX counts 2, 4, 8
and 16 rather than 27 near-identical dumps of a state that has stopped changing.
When transmission resumes it writes `TX_RESUMED after=N` into `samples.log`, so a
stall that recovers on its own is distinguishable from one that ends in a reboot.

Each snapshot holds the last healthy `ethtool -d` register dump immediately above
the stalled one, then `ethtool -S`, the `end0` IRQ line, `ip -s link`, qdisc
backlog, `softnet_stat` and a dmesg tail.

New variables in `defaults/main.yaml`: `net_recorder_stall_after` (2),
`net_recorder_stall_max_dumps` (6), `net_recorder_regs_every` (6).

## What to read when a snapshot appears

Two independent reads, either of which settles it.

**1. The two counters in `ethtool -S`.** This needs no register decoding:

```
tx_frames:      <- the MAC hardware
q0_tx_packets:  <- the driver, incremented when it reclaims a descriptor
```

If `q0_tx_packets` climbs across the four snapshots while `tx_frames` sits frozen,
the driver reclaimed descriptors the hardware never transmitted. That is the
hypothesis, proven.

**2. The register diff.** On a healthy node the TX and RX queue pointer words
advance between every pair of dumps. If the TX pointer is frozen while the RX
pointer still moves, the TX DMA has halted rather than merely having nothing to
send.

`ethtool -d` on `macb` emits the driver's `get_regs` array rather than raw register
offsets, so the dumps are deliberately **not** decoded in the script — naming the
words would mean guessing their order. The healthy/stalled diff carries the meaning
and assumes nothing about which word is which. Decode it properly against
`macb_get_regs` in the kernel source once there is a real sample to check against.

Also worth a look: qdisc `backlog` should be ~0. Anything else would mean packets
are piling up above the driver and would point somewhere else entirely.

## Design notes

- **Snapshot on the 2nd consecutive zero, not the 1st.** This node runs k3s and
  renews a kubelet lease every few seconds, so it is never legitimately silent for
  20s, but a single quiet interval is not worth a snapshot.
- **`d_tx_pkts` is `NA` on the first sample after a start.** That is a missing
  reading rather than a stall, so only a literal `0` counts. Tested.
- **The healthy baseline is only ever taken while TX is confirmed moving**, so it is
  always a genuine working reference. It lives in `/run`, costing no disk writes,
  and is copied into `stall.log` on disk when a stall fires.
- **`healthy_tick` starts at the limit** so the first healthy sample captures a
  baseline immediately. A stall arriving in the first minute would otherwise have
  nothing to compare against.
- **Every command is wrapped in `timeout`.** A sick driver can block an ioctl
  indefinitely, and a snapshot that hangs the sampler would cost us the samples,
  which matter more than the snapshot.

## Verification done

- Backoff logic tested against four sequences including the real 27-sample episode
  shape. Snapshots fire at 2, 4, 8, 16; a leading `NA` does not count as a stall; a
  single quiet interval does not fire; baselines refresh every 6 healthy samples.
- The deployed `stall_snapshot` function was executed directly on `lib-pi-05`
  against `end0`. Every section produced real output and the two register dumps
  showed the queue pointer words differing between them.
- `stall.log` created, `regs.healthy` captured on the first healthy sample, service
  active with the new arguments.

## Acceptance criteria

- A stall produces a `stall.log` entry that survives the watchdog reboot.
- That entry answers, from `ethtool -S` alone, whether `q0_tx_packets` advanced
  while `tx_frames` was frozen.
- Findings recorded here, and the spec's confidence note updated to match.

## Interaction with other tickets

Nothing else may change on `lib-pi-05` until a snapshot has been captured, or until
02 is deliberately started knowing this may never fire again.
