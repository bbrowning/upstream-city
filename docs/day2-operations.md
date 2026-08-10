# Day-2 operations — Dolt storage & backups

Scope: how our city's Dolt store is backed up, how to restore it, and the one
recurring task that is *yours* to do. Grounded against gascity **v1.4.0**; the
remediation below was executed and verified **2026-08-10**.

New day-2 topics (agent ops, cost, worktree cleanup) go in new sections/docs —
this one is storage + backups only.

---

## What you need to know

- **In-container backups are automatic.** The `mol-dog-backup` order writes a
  full `dolt backup` snapshot of every DB to `/pvc/workspace/.dolt-backup/<db>/`
  every 6h. No credentials, no action needed.
- **The store is local-only.** No Dolt git remotes (they can never be pushed to
  from this read-only container, so they only ever produced noise + cache bloat).
  Do **not** re-add them — see [What was fixed](#what-was-fixed-2026-08-10).
- **Your one recurring job: copy `.dolt-backup/` off the PVC, from the host.**
  Same-volume snapshots don't survive volume loss, and the container has no
  offsite credentials by policy. Durability = the host copy-out. See
  [Offsite copy-out](#offsite-copy-out-host-side).

That's it. Everything else here is reference for when something looks wrong.

---

## Offsite copy-out (host side)

The container stages a single rolling mirror in `.dolt-backup/`; the host is
responsible for pulling it offsite and keeping dated generations. On your
host/laptop, on a cadence ≥ the 6h backup interval:

```bash
# 1. pull current mirror off the PVC (adjust access path: kubectl cp / mount / rsync-over-ssh)
rsync -a --delete  <pvc>:/pvc/workspace/.dolt-backup/  ~/gascity-backups/current/

# 2. snapshot a dated generation (hardlinks = cheap history; container keeps only the rolling copy)
cp -al  ~/gascity-backups/current/  ~/gascity-backups/$(date +%F-%H%M)/
```

Open decisions (fill in once chosen): **offsite destination** = _TBD_;
**retention / RPO** = _TBD_ (how many generations, how often you pull).

---

## Restore / disaster recovery

Each `.dolt-backup/<db>` is a complete `dolt backup` target carrying full commit
history, so a restore is point-in-time within that history:

```bash
dolt clone file:///pvc/workspace/.dolt-backup/<db> <db>
```

Offsite restore is identical — clone from wherever the host stored the copy.

**An untested backup is not a backup.** Restore-into-scratch and check row counts
at least whenever the backup mechanism or the Dolt version changes.

---

## How backups work here

Dolt is "git for data": a backup is a full, commit-versioned mirror of the DB, so
you can roll back to any Dolt commit, not just last night's dump. gascity drives
this with scheduled **orders** (controller jobs). Storage-relevant ones:

| Order | Interval | What it does |
|---|---|---|
| `mol-dog-backup` | 6h | `dolt backup` each DB to `file://.../.dolt-backup/<db>`. **This is our backup.** |
| `mol-dog-compactor` | 2h | `gc dolt compact`: flatten history above threshold + GC to reclaim space (local, no push). |
| `dolt-remotes-patrol` | 15m | `gc dolt sync` — a no-op now that there are no remotes. |
| `mol-dog-doctor` | 5m | `gc doctor` — keeps the store local-only (strips any off-box remote). |

Config knobs (rarely needed):

- `GC_BACKUP_ARTIFACT_DIR` — backup dir (default `$GC_CITY_PATH/.dolt-backup`).
- `GC_BACKUP_OFFSITE_PATH` — optional in-city rsync hop; **not** a substitute for
  the host copy-out.
- `GC_BACKUP_DATABASES` — restrict which DBs are backed up.
- `dolt.local-only: true` — set in every `.beads/config.yaml`; the doctor strips
  git/http/ssh/s3 remotes but whitelists `file://` and absolute paths, so the
  filesystem backup coexists with local-only.

---

## Monitoring & capacity

- **Healthy signals:** `gc order list` all healthy; `.dolt-backup/<db>` mtimes
  advancing every 6h; **no** files under
  `.gc/runtime/packs/dolt/compact-pending-push/`; `gc status` store size tracks
  real data (~230 MB today, not GB).
- **Capacity is not a concern.** `/pvc` is ~26% used (~1.4 T free). Real bead data
  is a few hundred MB total. (`gc status` may show `Live rows: 0` — a
  row-count display quirk in this build, not data loss.)
- **Pruning/history:** the compactor flattens in-DB history above 2000 commits and
  GCs; the filesystem backup is a rolling mirror, so *generational* retention is
  whatever the host copy-out keeps.

---

## What was fixed (2026-08-10)

The store had ballooned to ~6 GB with a stream of controller wisps. Root cause was
**not** missing backups — those already ran. Every DB had been seeded (by
`bd bootstrap`) with a `git+https://…upstream-city.git` remote, which this
read-only container can never push to. Each failed push (every 15m/2h) left
`compact-pending-push` markers that quarantined compaction and fired wisps, and
piled un-repacked loose git objects into `git-remote-cache` — **5.7 GB of a
git-shaped copy of ~230 MB of real data.**

Remediation (all local-write-only, no credentials):

1. Verified filesystem backups restore (`dolt clone` from `.dolt-backup/`).
2. Set `dolt.local-only: true` in all `.beads/config.yaml` and removed the
   `origin` remotes → zero remotes → compaction push is a clean no-op, no marker.
   (Config backups: `*.bak-20260810-190700`.)
3. Cleared the stale `compact-pending-push` markers and the 22 duplicate wisps.
4. Removed the dead `git-remote-cache/` dirs (regenerable; tied to the deleted
   remotes) → store back to **231 MB**.

Steps 5–6 (host offsite copy-out; steady-state verification) are the ongoing
host-side responsibility above. **Do not re-add Dolt remotes** — see
`rigs/gascity/AGENTS.md:523`.
