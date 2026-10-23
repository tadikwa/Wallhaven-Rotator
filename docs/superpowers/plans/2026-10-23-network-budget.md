# Persistent Wallhaven API budget implementation plan

Goal: bound all search/metadata traffic across clicks, rotations and restarts,
then prefer qualified candidates over new requests. Execute inline, autonomously.

Architecture: keep the existing PowerShell runtime and dependency-free shared
policy. A separate atomic api-budget.json plus a short named mutex records
permits and cooldowns. Dispatcher ticks resume deferred requests without sleep.
The existing metadata/history policies remain authoritative. A bounded search
cache retains discoveries (15 minutes) and each selection deduplicates IDs/URLs.

Constraints: PowerShell 5.1, Windows 10/11, Strict, 32:9, daily exclusions and
shared history unchanged. No user-state reset, merge, release or installation.

Ruling: shared cap 24/60s and Rotator cap 12/60s, minimum spacing 2.6s.
Screensaver main currently permits 30/min independently; reserving headroom
gives 42 combined under that assumption. Its installed version is unknown.
No claim can cover other machines/apps behind the same public IP.

Ruling: total selection budget is 2 searches + 6 metadata calls, never reset
by recycling. A 45s selection deadline bounds deferred work; long throttling
keeps the current image. Cached Strict decisions are always recalculated.

Tasks (RED -> GREEN for each; one full CI cycle after integrated checks):

- [x] Shared permits/cooldown: modify src/Wallhaven-SharedPolicy.ps1; add
  tests/ApiBudget.Tests.ps1. Test sliding windows, restart, lock contention,
  concurrent cooperating processes, corruption, clock rollback, Retry-After.
- [x] Network gateway and asynchronous deferral: modify runtime; adapt existing
  engine fixture to virtual time, retain failure/reservation assertions.
- [x] Candidate/search cache and diagnostics: runtime only, local-first,
  qualified-first, deduplication, atomic bounded persistence, aggregate summaries.
- [x] Simulated manual/automatic cold/warm/saturated/429 loads: add
  tests/NetworkLoad.Tests.ps1 and CI step. Record real emitted transport calls,
  sliding-window maxima, metadata cache hit fraction and elapsed virtual time.
- [ ] Whole suite, Go tests, existing build, independent read-only review,
  commit/push same PR, inspect exact commit CI (at most three push/CI cycles).

Review focus: no permit bypass; no stale/unknown Strict acceptance; no shared
history writes for technical rejections; no busy-loop or blocking sleep; no
false promise of coordination with an unmodified Screensaver/NAT clients.

External evidence consulted 2026-10-23:
- https://www.whvn.cc/help/api (official API documentation, 45 calls/min).
- tadikwa/Wallhaven-Screensaver main/src/WallhavenScreensaver/WallhavenClient.cs
  blob 4abf8c7ba87b91f69989a4088f486f7f7046525b: in-memory process-local 30/min.

Validation ledger: fill tests/NetworkBudget-results.md from executable results.

Local verification 2026-10-24: eight PowerShell 5.1 suites passed, Go1.23.2
tests passed, existing build/go vet passed. Independent review defects (deadline
and the historical fixture quota) reproduced and fixed; late429 regression also
reproduced/fixed and independently rechecked. No remaining demonstrated defect.
CI commit/push step remains pending at preparation of this commit.
