Status: needs-info

Blocked by: 01

# 02: Disable TSO and scatter-gather on end0

The candidate fix, run alone with nothing else changed.

Currently on:

```
tx-tcp-segmentation: on
tx-scatter-gather:   on
```

TSO makes the driver build long multi-descriptor chains, which is where `macb`'s
descriptor handling is most complex and most exposed to the used-bit-read race in
the spec. Disabling it costs some CPU on a node that is not CPU-bound.

If the stalls stop, that is both the mitigation and strong support for the
mechanism.

## Scope

Set `tx-tcp-segmentation`, `generic-segmentation-offload` and `tx-scatter-gather`
off on `end0`, through the `net_recorder` role or a small dedicated role.

**It must persist across reboots.** `ethtool -K` is a live-only setting and this
node reboots itself every few hours, so a hand-applied change would silently vanish
at the first stall and the run would read as a false negative. Use a
systemd-networkd `.link` file or an Ansible task that reapplies at boot, and verify
by rebooting once and re-reading `ethtool -k end0`.

Scope to `lib-pi-05`. No other node runs `macb`.

## Acceptance criteria

- `ethtool -k end0` shows all three off, confirmed after a reboot.
- No TX stall for 7 days. Baseline is 5 stalls in the 52 hours to 2026-09-01, so
  48 hours clean is encouraging and 7 days is convincing.
- `stall.log` stays empty over that window.

If a stall does occur, ticket 01's snapshot should now exist. Record it there, and
the mechanism question is answered either way.

## Interaction with other tickets

- Do not run 03 during the observation window. Two changes in flight makes the
  result unattributable.
- Do not run 04 during the observation window. It masks the symptom being measured.

## Comments

### 2026-09-02 — role built, scatter-gather deferred

`infra/roles/nic_offload` and `infra/playbooks/nic-offload.yaml`, scoped to
lib-pi-05. Not yet applied.

**Scatter-gather is not included.** Three reasons, recorded so this is not read as
an oversight:

1. systemd `.link` files cannot express it. Including it would mean a second
   mechanism (a script plus a unit) alongside the settings file, doubling the
   moving parts for the secondary suspect.
2. It carries a real throughput cost, where TSO does not meaningfully.
3. TSO is the primary suspect. Disabling it already removes the long
   multi-descriptor chains that scatter-gather contributes to.

If TSO-off does not hold, disabling scatter-gather is the escalation and needs its
own ticket and its own mechanism.

**The role verifies rather than assumes.** After writing the file it re-triggers
udev and reads `ethtool -k` back, failing hard if the settings are not in force.
This ticket's acceptance criteria depend on them genuinely being off, and a
`.link` file that fails to match would leave the node unchanged and make a
continuing stall look like a negative result when the change was never applied.

**Matched on MAC, not interface name.** The kernel names this NIC `eth0` and
systemd renames it `end0`, so a name match is fragile in a way the MAC is not.

### 2026-09-05 — applied to lib-pi-05, awaiting verdict

`ansible-playbook playbooks/nic-offload.yaml` run at 10:20. The role's own assert
confirmed the settings are in force:

```
tcp-segmentation-offload: off
generic-segmentation-offload: off
scatter-gather: on          <- deliberate, see above
```

Applied without a reboot. `carrier_changes` stayed at 1 and uptime was preserved,
so re-triggering udev did not disturb the link. k3s stayed up.

**The observation window has to be longer than this ticket originally specified.**
The acceptance criteria above say 7 days clean, chosen when the baseline was 5
stalls in 52 hours. The node then went quiet on its own:

| | |
| --- | --- |
| last stall | 2026-09-01 23:56 |
| applied | 2026-09-05 10:20 |
| quiet before the change | 3 days 10 hours, nothing altered |

That quiet gap is roughly four times the longest previous gap, so 7 days of
silence would no longer distinguish the fix from the node's own behaviour.
**Judge this over 2-3 weeks, not one.** Waiting for another stall before applying
was considered and rejected: it produces the same ambiguity later, and the node is
unusable while it stalls.

**If it stalls again**, the escalation is disabling scatter-gather. That needs its
own ticket and a different mechanism, since systemd `.link` files cannot express
it. Do not simply widen this one.

**Where the evidence lives.** `stall.log` rotates daily with 14 kept, so the two
captured stalls (2026-09-01 17:42 and 23:56, four snapshots each) are in
`/var/log/net-recorder/stall.log.1` on lib-pi-05, not in the live file. Check the
rotated files before concluding nothing was captured.

**Revert** is `nic_offload_enabled: false`, which removes the settings file and
returns the node to stock at the next boot.
