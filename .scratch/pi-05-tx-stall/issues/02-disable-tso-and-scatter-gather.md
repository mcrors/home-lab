Status: ready-for-agent

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
