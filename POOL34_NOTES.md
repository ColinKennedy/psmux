# Pool depth 3 or 4: handoff notes (agent a6e27dde, 2026-10-08)

Task: raise the default warm pane pool depth (`warm-pool-size`) from 2 to 3 or
4 so the 4th new-window after a cold launch stops stalling 1.5 to 2.4 s.
Branch: this worktree branch. Nothing merged, nothing pushed. No code change
made yet: only this file and the probe were committed.

## Where the default lives

* `src/types.rs` `WARM_POOL_SIZE_DEFAULT` (currently 2), used by
  `default_warm_pool_size()` (env `PSMUX_WARM_POOL_SIZE` overrides, `PSMUX_NO_WARM`
  forces 0, max `WARM_POOL_SIZE_MAX` = 8).
* `src/server/option_catalog.rs` line ~275: catalog default string "2".
* `src/server/mod.rs` ~2530: the owed standby spawn waits for
  `ready_len >= effective_target.min(WARM_POOL_SIZE_DEFAULT)`. If the default is
  raised, introduce a separate const that keeps this at 2, otherwise the
  standby waits for 3 or 4 ready spares (backstop STANDBY_OWED_MAX 2 s) and the
  shipped behaviour would differ from what an env override measures.
* Docs: `docs/warm-sessions.md` "Pool Depth" section says default two, and the
  section "The third quick creation at depth two".
* Tests: `tests-rs/test_warm_pool_depth.rs` (default >= 2),
  `tests-rs/test_config_option_parity.rs` uses "3" as a sample value (check it
  still differs from the default if 3 is chosen), `tests/test_creation_latency_gate.ps1`
  header comment already has pool 2/3/4 cadence numbers.
* Boot path: `BootHold` (types.rs ~560) already holds every spare until pane one
  has its prompt, then `trickle_deficit` (pane.rs ~1431) spawns ONE spare at a
  time until one is ready. So cold launch should not get slower with a deeper
  pool, but see the finding below.

## Probe

`tests/probe_pool_depth_cold_launch.ps1` (also in scratchpad as pool_probe.ps1).
Per run and depth: fresh `-L pool34_<pid>_<run>_<d>` namespace,
`new-session -d -x 160 -y 45`, cold launch to pane one prompt, then five
`new-window -P -F '#{pane_id}'` each timed to its prompt over TCP, then 9 s
settle and a burst of 8 new-window (each time to prompt), then a separate fresh
namespace idle 14 s for WorkingSet sum and process count (server + standby +
all descendants). Depth set with `PSMUX_WARM_POOL_SIZE` on the same binary.
Cleanup: `-L <ns> kill-server`, then Stop-Process only for PIDs still in that
namespace's process tree.

    $sp = <scratchpad>; pwsh -NoProfile -File tests\probe_pool_depth_cold_launch.ps1 -Binary $sp\before\psmux.exe -Depths "2,3,4" -Runs 6 -Out $sp\env_234.json

BEFORE binary: master d19e9905 release build copied to
`<scratchpad>\before\psmux.exe`.

## Measured so far (master d19e9905)

Smoke, depth 2 (default), 1 run:
cold 893 ms, windows [797, 75, 2, 1903, 250] ms, burst of 8 to prompt
[1794, 1798, 2767, 2843, 2844, 3314, 3315, 3189] ms.

Six runs that were MEANT to be 2,3,4 but, because of the [int[]] parsing bug
above, ran at depth 234 which clamps to 8 (so this is depth 8 data):

    run cold  windows (ms to prompt)      burst of 8 (ms)              idle MB procs
    1   770   1733, 275, 3, 2, 2          17..24                        1185   26
    2   771   1663, 315, 2, 2, 2          11..17                        1177   26
    3   806   1640, 265, 2, 2, 2          8..15                         1185   26
    4   801   1735, 407, 2, 2, 2          10..16                        1185   26
    5   802   1644, 390, 2, 2, 1          9..14                         1177   26
    6   799   1665, 392, 2, 2, 1          10..16                        1174   26

## KEY FINDING so far

Even at depth 8 the FIRST new-window right after a cold launch takes 1.6 to
1.7 s and the second 265 to 407 ms. Depth does not help a creation that comes
immediately after pane one's prompt, because the boot hold keeps the pool
empty until then and the trickle then boots one spare at a time. In this probe
the stall moved from window 4 (depth 2: 1903 ms) to window 1 (depth 8). The
real user scenario (owner's report: creation four stalls) may have a gap
between launch and the first new-window; the probe should also be run with a
short delay (e.g. 1 to 3 s) after the cold prompt to model a human, and with
the immediate cadence, for depths 2, 3, 4.

## Left to do

1. Rerun the probe with `-Depths "2,3,4"` (fixed parsing), 6+ runs, plus a
   variant with a human gap after the cold prompt.
2. Pick 3 or 4, change `WARM_POOL_SIZE_DEFAULT`, catalog default, keep the
   standby owed threshold at 2 via its own const, update docs and unit tests.
3. AFTER measurements with the identical probe; check cold launch unchanged.
4. Suites against the worktree binary (they prefer target\release, or
   -Binary / PSMUX_EXE): test_creation_latency_gate.ps1, test_pane_startup_perf.ps1
   (check it for bare `kill-server` at line ~202 before running: it may need
   PSMUX_DATA_DIR isolation), test_issue659_warm_claim_environment.ps1,
   test_issue661_warm_pool_depth_holds.ps1, test_issue686_pool_surge_and_reap.ps1,
   warm suites (grep each for Stop-Process / taskkill by name first;
   test_warm_chain_runaway and repro_warm_server_leak kill broadly, do not run).
5. Add a 4th window after cold launch cell to a gate with JSON metrics in
   $env:USERPROFILE\.psmux-test-data\metrics.

State at handoff: no pool34 processes or namespace files left; default
namespace had no server before and after.
