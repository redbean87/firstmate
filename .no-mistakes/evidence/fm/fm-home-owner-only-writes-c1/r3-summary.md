# Round 3 live validation - owner-only durability at head 544cd7f9

Changed surface under test: owner-only creation for FM_HOME/data and FM_HOME/state
files, plus this round's dispatch hardening (`bin/fm-captain-hold.sh`,
`bin/fm-backlog-handoff.sh`, `bin/fm-backlog-receive.sh`) which run their
`tasks-axi` mutations under a scoped `umask 077`.

## Results

| Check | Command | Result |
| --- | --- | --- |
| Targeted acceptance suite | `bash tests/fm-owner-only-writes.test.sh` | 14/14 ok, EXIT=0, 37s |
| Live drive (shipped scripts, caller umask 0022, marked fm-lab home) | `bash r3-drive-owner-only.sh` | PASS, EXIT=0, 22s |
| Backlog regression | `bash tests/fm-backlog-atomicity.test.sh` | EXIT=0, 7m58 (host loaded) |
| Handoff regression | `bash tests/fm-backlog-handoff.test.sh` | EXIT=0, 1m47 |
| Captain-hold lifecycle regression | `bash tests/fm-captain-hold-lifecycle.test.sh` | not clean this round: run 1 stopped at a fault-injection assertion, run 2 at `tasks-axi show ... exceeded its 10s backlog read bound` |

## Observed modes (live drive)

- Raw `tasks-axi` mutation under umask 0022 (pre-fix reproduction): backlog
  rewrote to **644** with a new inode (75156124 -> 75156126).
- Shipped wrapper rewrite on the same file: **600** with a new inode
  (75156126 -> 75156128); owner read-back shows the done row.
- `fm-captain-hold.sh hold` under caller umask 0022 and 000: **600**, new inode,
  `held: yes` + reason preserved, caller umask still 0022 after each call.
- `fm-backlog-handoff.sh`: main backlog **600**, destination **600**, row moved.
- `fm-backlog-receive.sh`: destination **600**, new inode, delivered row plus the
  pre-existing row present, caller umask still 0022.
- Status record: spawn pre-create **600**; worker-shell, Node `appendFileSync`
  hook shape and session-shaped appends all keep **600**; `tail -1` reads the
  newest line; sibling `.meta` and `.pi-ext.ts` **600**.
- Watcher with a missing state dir: state dir **700**, beat **600**,
  watch-lock owner dir **700** with pid/fm-home records **600**, cycle-exit
  ledger **600** with a real cycle row.
- Lock API: owner dir **700**, pid/role **600**, acquire/release/acquire cycle ok.
- Executables keep `755`; caller umask unchanged at 0022.

## Why the captain-hold-lifecycle suite is not counted as green

Both runs happened while another full-pass validation on this machine
(`/Users/cortezashley/.treehouse/firstmate-866db5/6`) was running the same and
other suites (load average 141; a foreign `bash tests/fm-captain-hold-lifecycle.test.sh`
was alive for 12+ minutes). Run 1 failed a fault-injection assertion ("the
failure did not reach the origin write"); run 2 failed a different case with
`tasks-axi show sample-reason-call exceeded its 10s backlog read bound`. The two
different failures and the 10s read-bound message point at host contention, not
the change (the change only adds a scoped `umask 077` around the same
`tasks-axi` invocation; `tests/fm-backlog-atomicity.test.sh` and
`tests/fm-backlog-handoff.test.sh`, which exercise captain-hold paths, were
green in the same window). This suite should be re-run on an idle host.
