Status: resolved

# 03: Fix the watchdog config defects

> **Start here:** all four sections are implemented and applied (2026-08-31). The only
> outstanding acceptance criterion is the 24h soak — flip `Status:` to `resolved` once
> it passes. The sections below are the original text; the comments at the bottom record
> what was actually decided and done, and supersede them where they differ.

## Background: how the watchdog actually works

Worth stating plainly, because the defect below only makes sense with it.

`/dev/watchdog` is a device file backed by a countdown timer on the board's own
silicon. Something in userspace has to write to that file regularly to say "still
alive". If the writes stop for longer than the timer allows, the chip resets the board
— no OS involvement, which is the whole point: it works even when the kernel is hung.

Two numbers control this:

- **hardware timeout** — how long the chip waits after the last write before resetting.
- **`interval`** — how often the `watchdog` daemon writes. Currently 15s.

The hardware timeout must be comfortably **larger** than `interval`. If they are equal,
any ordinary scheduling delay means the timer expires before the daemon's next write
and the board reboots for no reason.

Each board family has a different timer chip and so a different kernel driver. These
are already set per group in `infra/group_vars/`:

- `bcm2835_wdt` — Broadcom, used by the pis
- `meson_gxbb_wdt` — Amlogic, used by the potatoes

## Context

Auditing the live `/etc/watchdog.conf` against `infra/roles/watchdog/` turned up four
defects. None caused the 2026-08-27 incident, but two mean the role does not do what
it appears to do.

Live config on lib-pi-01:

```
realtime		= yes        <- shipped by the package, outside the ANSIBLE block
priority		= 1
watchdog-device = /dev/watchdog   <- ANSIBLE block begins
interval        = 15
realtime        = no
priority        = 1
max-load-1      = 24
min-memory      = 0
ping            = 192.168.1.1
ping-count      = 3
```

## Scope

### 1. `watchdog_timeout` does nothing — and must not be switched on as-is

`infra/vars/main.yaml` sets `watchdog_timeout: 15`, but the `blockinfile` in
`infra/roles/watchdog/tasks/main.yaml` never writes a `watchdog-timeout` line. There is
no such line in the live file. The variable has never had any effect.

**Do not just plumb it through.** `interval` is also 15, so setting the hardware
timeout to 15 puts both numbers equal — the failure described above, on all five
watchdog nodes. The potatoes currently run a 60s hardware timeout against the 15s
interval, a healthy 4:1 margin that exists *only because the variable was dead*.

So the variable needs a correct value, not just wiring.

**The open question — what is the pis' hardware timeout?**

The kernel publishes device properties as files under `/sys` (a virtual filesystem
that exposes kernel state as readable files). For a watchdog they live in
`/sys/class/watchdog/watchdog0/`. `wdctl` is a command-line tool that reads and
formats the same information.

On a potato this works and tells us what we need:

```
$ cat /sys/class/watchdog/watchdog0/{identity,timeout,min_timeout,max_timeout}
Meson GXBB Watchdog
60          <- current hardware timeout, seconds
1           <- minimum settable
0           <- 0 means the driver reports no maximum
```

On a pi it tells us nothing. The files do not exist at all — the `bcm2835_wdt` driver
does not publish them:

```
$ cat /sys/class/watchdog/watchdog0/timeout
cat: /sys/class/watchdog/watchdog0/timeout: No such file or directory
```

And `wdctl` cannot read the device directly, because the running `watchdog` daemon
holds it open exclusively:

```
$ wdctl
wdctl: cannot read information about /dev/watchdog0: Device or resource busy
```

So on the pis we currently have no way to see what hardware timeout is in force or how
high it can be set. Broadcom's timer is understood to max out near 16 seconds, which
would mean a 60s request cannot be honoured directly — the kernel may either extend it
by pinging the chip internally, or silently clamp it. We should not guess.

**To resolve:** stop the `watchdog` daemon on **one** pi, which releases the device,
then run `wdctl` to read the real values. Restart the daemon afterwards. Record the
numbers in the comments below.

Then pick one:

- **Option A (low risk):** leave `watchdog-timeout` out of the config entirely and
  delete `watchdog_timeout` from `infra/vars/main.yaml`, with a comment recording that
  the driver default is deliberate. This is exactly what has been running for months.
- **Option B (explicit):** set it per board group. `potatoes` and `pis` already carry
  `watchdog_kernel_module` in their group_vars, so a per-group `watchdog_timeout` fits
  naturally. Needs the measured pi number, and must keep at least a 3:1 margin over
  `interval`.

### 2. `retry-timeout` is not set

`retry-timeout` is how long a failing check must keep failing before the daemon acts.
It is absent from the config, so the daemon uses its built-in default of 60s.

The tolerance is therefore already about a minute, not the 15 seconds that `interval`
suggests. Worth making explicit rather than inherited. Add `watchdog_retry_timeout` to
`defaults/main.yaml` and write a `retry-timeout` line.

This also corrects a misreading from the incident: raising `interval` would **not**
have prevented 2026-08-27, because the gateway stayed unreachable well past 60s.

### 3. Remove `max-load-1`

`max-load-1 = 24` reboots the node when the 1-minute load average exceeds 24.

Load average on Linux counts processes waiting on disk or network I/O, not just
processes using CPU. An NFS server that stops responding will drive load into the
dozens on a node that is otherwise idle. So this setting reboots nodes for being
*blocked*, which is not what a watchdog is for.

This is the leading suspect for lib-pi-05, which reboots unexplained and did so again
at 19:00 on 2026-08-27. The standing theory in the operator's notes is simultaneous
sonarr and radarr NFS scans. If that is right, the watchdog has been rebooting a
healthy node for months.

We cannot prove it yet, because the reboot destroys the evidence — ticket 01 fixes
that. Remove the setting now and revisit if lib-pi-05 keeps rebooting once we can see
why.

### 4. Duplicate `realtime`

The package ships `realtime = yes`; the Ansible block below it sets `realtime = no`.
The later line wins, so the behaviour is `no`, but the file reads as contradictory.
Have the role replace the package's line rather than appending underneath it.

## Acceptance criteria

- The measured `bcm2835_wdt` timeout values are recorded in the comments below, and
  Option A or B is chosen with a one-line reason.
- Either `watchdog-timeout` is present with a value at least 3x `interval`, or
  `watchdog_timeout` is deleted from `infra/vars/main.yaml`. Not the current state,
  where it exists and does nothing.
- `retry-timeout` is present and matches the role variable.
- No `max-load-1` line remains; `watchdog_max_load1` is removed from
  `infra/vars/main.yaml`.
- Exactly one `realtime` line in `/etc/watchdog.conf`.
- All five nodes run 24h with no reset carrying a `max-load-1` trip in its journal.
  (Restated 2026-08-31 from "no unexplained reset." lib-pi-05 will still reset from
  the network wedge tracked separately, and that is not a failure of this ticket.)

## Comments

### 2026-08-30 — the open question can be answered from the journal, without stopping the daemon

This ticket proposes stopping the `watchdog` daemon on a pi to release `/dev/watchdog` so
`wdctl` can read the hardware timeout. That is no longer necessary. The daemon prints
both values in its startup banner, and ticket 01 now makes that banner survive reboots.
From `lib-potato-04`:

```
watchdog[1889]: starting daemon (5.16):
watchdog[1889]:  int=15s realtime=no sync=no load=24,18,12 soft=no
watchdog[1889]:  error retry time-out = 60 seconds
watchdog[1889]: watchdog now set to 60 seconds
watchdog[1889]: hardware watchdog identity: Meson GXBB Watchdog
```

So on any watchdog node:

```sh
journalctl -u watchdog --no-pager | grep -E "watchdog now set to|identity"
```

Run that on a pi and it answers the `bcm2835_wdt` question directly — and it reports what
the driver actually *accepted*, which is the number that matters. `wdctl` and `/sys` would
only have shown what was requested. No service interruption, no risk.

### Two things this run already confirms

- **§2 is right.** `error retry time-out = 60 seconds`, and the observed trip was
  `Retry timed-out at 75 seconds` (five failures at 15s intervals). Tolerance is ~60–75s,
  not the 15s that `interval` suggests. Worth making explicit as the ticket proposes.
- **§3, the derived load thresholds.** `load=24,18,12` — the daemon derives 5- and
  15-minute limits from the single `max-load-1 = 24`. So removing `max-load-1` removes all
  three, which is the intent.

### 2026-08-30 — §2 decided and implemented: retry-timeout = 240

`watchdog_retry_timeout: 240` added to `roles/watchdog/defaults/main.yaml` and written
into `/etc/watchdog.conf` by the blockinfile. Operator's call: 4 minutes.

Reasoning recorded so it is not relitigated. Kubernetes waits ~300s before evicting pods
from an unreachable node. 240s sits under that, so a node that is coming back reboots and
rejoins before the control plane starts relocating anything. Setting it at or above 300s
would race the two against each other.

This does not change the hardware timer, which stays at the driver default (60s on the
potatoes). The daemon keeps petting `/dev/watchdog` throughout the retry window — proved
by the 2026-08-30 trip, where checks failed for 75 continuous seconds against a 60s
hardware timer without the board resetting. Only the *decision* to reboot is delayed.

Not yet applied to any node — needs a `playbooks/watchdog.yaml` run, which restarts the
watchdog daemon on all five watchdog hosts.

Partial mitigation for ticket 07: the boot-time trip happened at 75s, so 240s gives the
network far more room to come up. It does not fix the underlying defect — a node whose
network never returns still loops — so 07 is still required.

### 2026-08-30 — §1 measured: both board families report a 60s hardware timeout

```
lib-potato-04: watchdog now set to 60 seconds
               hardware watchdog identity: Meson GXBB Watchdog
lib-pi-01:     watchdog now set to 60 seconds
               hardware watchdog identity: Broadcom BCM2835 Watchdog timer
```

The pi reports the same 60s as the potato. That contradicts the expectation recorded in
this ticket — that Broadcom's timer maxes near 16 seconds and a 60s request could not be
honoured.

**Both can be true.** The BCM2835 counter really is limited to roughly 16 seconds, but the
Linux watchdog core supports a driver advertising `max_hw_heartbeat_ms` below the
requested timeout, in which case the *kernel* pings the chip on userspace's behalf and
presents the longer timeout upward. The daemon then reports 60s because that is genuinely
the timeout in force for it.

Practical consequence, if that is the mechanism: a dead watchdog daemon is caught at 60s
(kernel keeps pinging until the software timeout expires), while a fully hung kernel is
caught in ~16s (the kernel's own pinging worker stops too). That is a better outcome than
a flat 60s, not a worse one.

This is inferred from how the watchdog core works, not verified on the hardware — the
driver does not publish `/sys/class/watchdog/watchdog0/timeout`, which is why the number
was unobtainable before. It does not affect the decision below either way.

**Option A chosen and implemented** (operator, 2026-08-30). `watchdog_timeout` deleted
from `infra/vars/main.yaml`, replaced with a comment recording the measured values and
why the driver default is deliberate. Leave `watchdog-timeout` out of the config and delete the
dead `watchdog_timeout` from `infra/vars/main.yaml`, with a comment recording that the
driver default is deliberate. Both families land on 60s against a 15s `interval` — the
4:1 margin this ticket asks for — and that is what has been running for months. Option B
would hard-code a per-group number that currently matches the default exactly, adding a
value to keep in sync for no behavioural gain.

### This removes a suspect for lib-pi-05

The ticket speculated the pis might be running a hardware timeout equal to `interval`,
which would reboot a healthy board on any scheduling delay. They are not — it is 60s
against 15s. So that is not why `lib-pi-05` reboots.

`max-load-1 = 24` remains the leading theory (§3), and with logs now persisting, the next
occurrence should show it directly rather than being reasoned about.

### Note on scope

Ticket 07 (watchdog reboots ~75s after every boot, because it starts before the network)
came out of the same logs. It is a separate defect from the four here, but it lands in the
same role and the same `/etc/watchdog.conf`, so sequence the two together to avoid
conflicting edits.

### 2026-08-31 — §1 and §2 closed; §3's lib-pi-05 justification is dead

**Status changed to `ready-for-agent`.** The header previously read `needs-info` /
`Blocked by: 02`. Neither is true of what remains: the measurement question is answered
(comment above), and nothing left here depends on ticket 02's peer-quorum work.

**§1 closed — Option A taken.** `watchdog_timeout` deleted from `infra/vars/main.yaml`,
with a comment recording that the driver default is deliberate. No `watchdog-timeout`
line is written. Both board families run 60s against a 15s `interval`.

**§2 closed.** `watchdog_retry_timeout: 240` added to `defaults/main.yaml` and a
`retry-timeout` line written by the role. Applied and verified on all five watchdog
nodes. 240s sits under the ~300s Kubernetes unreachable eviction so a returning node
rejoins before its pods relocate.

Both landed in commit `cdee18e`.

#### §3 — remove `max-load-1` anyway, but not for the reason written above

The ticket says `max-load-1` is "the leading suspect for lib-pi-05" via simultaneous
sonarr/radarr NFS scans, and the comment above says the next occurrence "should show it
directly." Three occurrences have since been captured with logs persisting — 2026-08-30
20:06, 2026-08-30 20:27, and 2026-08-31 15:27 — and they show something else.

lib-pi-05's fault is a **network wedge**: `end0` keeps carrier and reports zero RX/TX
errors, but all LAN traffic stops at once (gateway, all three control planes, NFS all
go `EHOSTUNREACH` simultaneously), and it never self-recovers without a reboot. **The
node is idle at onset — no CPU, memory, disk or conntrack pressure.** What reboots it is
the *gateway ping* check timing out (~270s of failures on 2026-08-31), not the load
check. Router and switch are ruled out: lib-pi-01 and lib-pi-03 run the identical
gateway ping and logged zero failures across the same window. The fault is local to the
board — most likely the `macb`/Cadence GEM RX path, or its switch port.

So: **`max-load-1` is not why lib-pi-05 reboots, and removing it will not stop those
reboots.** Do not treat pi-05 as the test of this change.

The general argument in §3 is untouched and still correct on its own: load average counts
processes blocked on disk and network I/O, not just CPU, so `max-load-1` reboots nodes
for being *blocked* rather than broken. That is not what a watchdog is for. Remove it.

Track the pi-05 network wedge separately — it is not a watchdog defect and does not
belong in this ticket.

#### Adjust the acceptance criteria before you start

"All five nodes run 24h with no unexplained reset" is no longer achievable and is not a
fair test of this ticket. lib-pi-05 will keep resetting until the network wedge is fixed,
for reasons unrelated to anything here. Either exclude pi-05 from that criterion, or
restate it as "no node resets with a `max-load-1` trip in its journal."

Also note the first two criteria are already satisfied by §1 and §2 above.

#### What is actually left

1. **§3** — remove the `max-load-1` line from the role's `blockinfile`, and delete
   `watchdog_max_load1` from `infra/vars/main.yaml`. Removing the single `max-load-1`
   also removes the daemon's derived 5- and 15-minute limits (`load=24,18,12`).
2. **§4** — have the role replace the package's shipped `realtime = yes` rather than
   appending `realtime = no` underneath it, so exactly one `realtime` line remains.

Both are edits to `infra/roles/watchdog/`. Sequence with ticket 07 as the scope note
above says — same role, same config file.

### 2026-08-31 — §3 and §4 implemented and applied; ticket complete

**§4 approach: the role now owns `/etc/watchdog.conf` outright.** The `blockinfile` is
replaced by a `template` task writing `roles/watchdog/templates/watchdog.conf.j2`.

Chosen over the narrower fix — rewriting the package's `realtime` line in place with
`lineinfile` — after inspecting the live file on all five nodes. The packaged file is 192
lines of which exactly **two** are active: `realtime = yes` (line 70) and `priority = 1`
(line 71). Everything else is documentation comments. Both active lines were duplicated by
the Ansible block; `realtime` contradicted it (`yes` then `no`), and `priority` agreed
(`1` then `1`), so the ticket's §4 defect had a silent twin it did not name.

Owning the file makes duplicate keys structurally impossible rather than fixed one key at
a time, and picks up the `priority` twin at no extra cost. The narrow fix would also have
split the role's config across two mechanisms — eight settings in a block, one in a
`lineinfile` — and any regexp keyed on the package's `= yes` breaks the moment
`watchdog_realtime` is set to `yes`.

Cost accepted: the packaged file's inline `man 5 watchdog.conf` commentary is gone, and a
setting omitted from the template is silently dropped. That risk is bounded by the audit
above — only two package lines were ever active, both already carried by role vars. Note
`/etc/watchdog.conf` is a dpkg *conffile*, but it was already locally modified by the
blockinfile, so dpkg's upgrade behaviour (keep ours, write theirs to `.dpkg-dist`) is
unchanged by this.

**§3:** no `max-load-1` in the template; `watchdog_max_load1` deleted from
`infra/vars/main.yaml`. Both the template and the vars file carry a comment on why the
absence is deliberate, so it does not get helpfully re-added.

**Verified on all five nodes** (lib-pi-01/02/03/05, lib-potato-04):

```
realtime lines: 1    priority lines: 1    active max-load settings: 0
banner: int=15s realtime=no sync=no load=0,0,0 soft=no
```

`load=0,0,0` — previously `load=24,18,12`. Removing the single `max-load-1` removed the
daemon's derived 5- and 15-minute limits too, as the 2026-08-30 comment predicted. A
second playbook run reported `changed=0`, so the template is idempotent.

#### Applying this rebooted all five nodes — and that is a separate defect

Every node went down shortly after the run. Not caused by anything in this ticket: the
settings in force are identical to before except the removed load check, and removing a
check cannot reboot a board.

**The explanation first written here was wrong and is corrected below.** It blamed the
role's handler for dropping `/dev/watchdog` across the restart, letting the hardware timer
run out. Ticket 08 investigated and disproved that. The handler, `wd_keepalive` and magic
close are all fine: the Debian `OnFailure=`/`Conflicts=` handoff fires and the device is
petted throughout the gap. Leave the handler alone.

The real cause is a defect in the `watchdog` 5.16 ping check. It stamps outgoing ICMP
echoes with its PID truncated to the 16-bit identifier field, then compares replies against
the untruncated PID (`src/net.c`), so any daemon above PID 65535 discards every reply and
scores every ping as failed. It then runs a clean shutdown after `retry-timeout`, about
270s later. `pid_max` here is 4194304, so a daemon restarted on a node with real uptime
always lands above the threshold, while a boot-time daemon draws a low PID and works. See
ticket 08 for the evidence.

So **any `changed` result on the config task costs a shutdown of all five watchdog nodes**
until ticket 02 lands and removes the built-in ping check. Anyone running
`playbooks/watchdog.yaml` should expect this and pick the timing deliberately;
`--check --diff` previews without paying it.

The 24h acceptance criterion above starts from this run, and these five resets are
explained — they carry no `max-load-1` trip.
