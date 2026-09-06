Status: resolved

Blocked by: 02

# 03: Move lib-pi-05 to a kernel with the macb TX recovery path

**Done 2026-09-06, landing on 6.18.44 rather than 6.18.42, and it is a recovery
mechanism rather than a fix. See the Answer at the bottom before reading the
original scope below.**

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

## Answer

**Deployed 2026-09-06.** lib-pi-05 runs `6.18.44-current-bcm2711` from Armbian
package 26.8.3. 26.8.1, the build lib-pi-02 runs, is no longer in the Armbian repo,
so the version was chosen by what was available and verified rather than by
matching the other node.

### Step 1 of the scope, whether it was worth doing, answered yes but not as assumed

The `macb` TX path did change, and the reason is now known upstream. It is not the
used-bit-read race this project assumed. The Cadence GEM in the RP1 sits behind
PCIe, and the TSTART doorbell write to the NCR register is a **posted** MMIO write
that can be dropped or delayed in the PCIe fabric, so the MAC never starts the TX
DMA. Documented in `raspberrypi/linux` PR #7340 and at
https://dtype.org/wiki/Cm5_macb_network_hang, with a signature matching ours
exactly: TX frozen, RX and interrupts continuing, carrier up, all error counters
zero.

### What is actually in the kernel we installed, and what is not

The May 2026 three-patch series that addressed the root cause (posted-write flush
after TSTART, ISR re-check after IER re-enable, an independent stall watchdog) was
**reverted in full on 2026-07-14**. What survives, from 2026-07-24, is a single
`macb_tx_timeout` callback that calls `macb_tx_restart`.

So this ticket delivers **recovery, not prevention**. lib-pi-05 will keep stalling.
It should now un-stick itself in about 5 seconds instead of dying for 4.5 minutes
and taking a watchdog reboot.

Verified on the binary before rebooting, then in the running kernel:

```
t macb_tx_timeout [macb]
t macb_tx_restart [macb]
```

### Why `NETDEV WATCHDOG` never fired, resolved

`netdev_watchdog_up()` in `net/sched/sch_generic.c` returns immediately when the
driver has no `ndo_tx_timeout`:

```c
void netdev_watchdog_up(struct net_device *dev)
{
	if (!dev->netdev_ops->ndo_tx_timeout)
		return;
```

`macb` in 6.18.10 had no such callback, so the transmit watchdog timer was never
armed on this node. The silence was never evidence about queue state, and it is not
a second defect. This closes the open question left in `../spec.md`.

The same fact is why the upgrade should help: registering `ndo_tx_timeout` arms the
timer for the first time. Our captures show the queue stopped and nothing dequeued
for the full 4m43s, which is exactly the condition `dev_watchdog` detects.

**Residual risk.** If `trans_start` keeps being refreshed during a stall,
`dev_watchdog` still will not fire and the callback never runs. The next stall
settles it either way.

## Acceptance criteria, as met

- `uname -r` reports 6.18.44. **Met**, and later than the 6.18.42 the title assumed.
- `ethtool -k end0` still shows ticket 02's settings. **Not applicable** — ticket 02
  was rolled back, and TSO, GSO and scatter-gather are deliberately all back on.
- `net_recorder` running and writing samples after the reboot. **Met.**
- No TX stall for 7 days. **Deliberately dropped.** Stalls are expected to continue;
  this ticket does not prevent them. The measure is now whether a stall recovers
  without a reboot, which `net_recorder` records as a `TX_RESUMED` line, and whether
  `journalctl --list-boots` gains an entry.

### Upgrade notes for the next time, this layout has a trap

`/boot/firmware` is a 512MB FAT partition on the SD card holding exactly one
`vmlinuz` and one `initrd.img`, no version suffix and no fallback entry, while `/`
is an LVM logical volume that the initramfs must activate before `root=UUID=`
resolves. If the kernel is replaced and the initramfs is not, `dm-mod` will not load
and the node lands at an initramfs prompt.

The Armbian postinst prints, alarmingly and harmlessly:

```
WARNING: Unsupported initramfs version (6.18.44-current-bcm2711) - skipping setup
WARNING: Unsupported kernel version (6.18.44-current-bcm2711) - skipping setup
NOTE: Manual boot configuration may be required
```

Those come from the `raspi-firmware` hooks, which do not understand Armbian version
strings. The `zzz-copy-new-files` hook that runs after them does the copy correctly.
Verify rather than trust, before rebooting:

```
sudo lsinitramfs /boot/firmware/initrd.img | grep -o 'modules/[^/]*' | sort -u
```

It must print the new kernel version.

Also worth knowing: the upgrade deletes the old `/lib/modules` tree, so a
`vmlinuz.old` fallback boots to a local console with no drivers and no network. Back
up `vmlinuz` and `initrd.img` on the FAT partition anyway; recovery is SD card into
a laptop and edit `config.txt`.

`linux-dtb-current-bcm2711` must be upgraded alongside `linux-image-current-bcm2711`
or apt leaves it behind. On this family it is close to vestigial — it installs to
`/boot/dtb-<version>/`, which nothing reads, and the DTBs that actually boot come
from the `linux-image` package — but the two nodes should not drift.
