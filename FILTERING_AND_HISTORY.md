# Filtering and anti-repeat architecture

Wallhaven Rotator always requests `purity=100`. The optional local filtering
layer is metadata-based and does not claim perfect image recognition.

## Content Filter Policy v5

- **Standard**: Wallhaven SFW only.
- **Reduced**: blocks strong adult/suggestive metadata but keeps ordinary
  subjects.
- **Strict**: conservative fail-closed policy ported from the Android project.
  It hard-blocks strong exposure/sexual concepts, rejects clearly female-focused
  subjects, fails closed for ambiguous Anime/People, and accumulates a risk
  score from weaker suggestive cues.

Reduced/Strict inspect `https://wallhaven.cc/api/v1/w/{id}` before download.
A custom query is preserved and combined with the policy's short negative query
where compatible with Wallhaven search syntax.

## Shared daily history

Desktop Rotator and Wallhaven Screensaver share:

`%LOCALAPPDATA%\WallhavenShared\history.json`

The v2 state stores unique Wallhaven IDs with the last successful local display
timestamp plus short-lived pending reservations. A named mutex coordinates both
processes and writes replace the JSON atomically.

Rules:

- `seenToday` is a hard exclusion.
- pending IDs owned by another active process/pool are a hard exclusion.
- rolling long-term history defaults to 5,000 IDs and is avoided during normal
  selection.
- only when a narrow source/query is exhausted can old history be recycled,
  oldest first and never from `seenToday`.
- an ID is committed only after `SystemParametersInfo` successfully applied the
  wallpaper.
- download/apply failures release the reservation and never consume the ID.
- deleting cached image files never changes history.

Legacy Rotator and Screensaver ID-only history files are imported as pre-today
long-term history because those formats did not contain timestamps.

## Profile/cache semantics

The desktop Rotator does not keep a prefetched candidate queue: its local image
cache is content-addressed by Wallhaven ID. Candidate eligibility (category,
query, filter, ratio and history) is evaluated before a cache hit is reused, so
changing profile/settings does not make a cached file bypass the active policy.
The global history is intentionally independent from profile changes.

## Diagnostics

Logs use explicit events:

- `candidate_rejected_daily_repeat`
- `candidate_rejected_recent_history`
- `candidate_rejected_pending_duplicate`
- `candidate_rejected_strict_filter`
- `candidate_accepted`

The Options panel also reports today's count, total history, cache size and
rejection counters.
