---
name: nabors-programme
description: How the NABORS Sauron build is versioned, assembled, and published - the nabors/stage tag-namespace trap, which VERSION file or submodule pointer a task actually moves, the ECR/ACR publish workflows, and the docker-inspect digest check that proves what is running on a box. Load before bumping a Sauron filter, cutting a nabors version, publishing a NABORS image, or verifying what a NABORS box (QA or rig) is actually running.
---

# NABORS Sauron build and publish

## The component map (verified against `origin/nabors` in each repo, 2026-09-01)

`sauron` is the framework: it loads detection filters as git submodules under `filters/`
(`.gitmodules` on `origin/nabors`, ~60 entries) and builds/publishes the `sauron-offshore`
image. Default branch is `stage`; NABORS work lives on `origin/nabors`.

The filters relevant to a "bump zones-detection" task:

- `altave-zones-detection` (`filters/altave-zones-detection`) - the redzone/greenzone/bluezone
  detection filter classes. Has its own `origin/nabors` branch, diverged from `main`.
- `altave-alert-emission` (`filters/altave-alert-emission`) - turns a detection into an alert.
  Also has its own `origin/nabors` branch, diverged from `main`.
- `altave-sauron-base` (`filters/altave-sauron-base`) - shared filter/frame/zone abstractions
  every other filter is built on. Stays on `main` for NABORS; no `nabors` branch exists.
- `altave-clip-handler` (`filters/altave-clip-handler`) - clip creation/upload library. Also
  stays on `main`; no `nabors` branch.

**The generalizable fact, not a zones-detection-only quirk:** any filter submodule *may* carry
its own `origin/nabors` branch that has diverged from `main` and lags it. `sauron-base` and
`clip-handler` don't; `zones-detection` and `alert-emission` do. Before touching a filter for a
NABORS task, run `git branch -r | grep nabors` in that filter's own clone - never assume `main`
is what NABORS ships.

## The version scheme: two lineages share one tag list

`sauron@origin/nabors`'s `VERSION` file reads `2.85.0-nabors.2` (verified 2026-09-01). Tag
`2.85.0` and `2.85.0-nabors.2` both exist in `git tag`. Tags `2.86.0` through `2.93.2` also
exist and belong to the **stage** lineage - `origin/stage`'s own `VERSION` is `2.93.2`, matching
the highest tag. The nabors line branched off `2.85.0` and bumps only its own suffix; it never
touches the `2.86.x`+ range, because that range is stage's.

**A candidate version is never inferred from `git tag` output alone** - a flat sorted tag list
interleaves both lineages and reads as one continuous sequence. Derive the next nabors version
from the current `origin/nabors` `VERSION` file, then prove no tag already claims it:

```bash
git -C sauron show origin/nabors:VERSION        # 2.85.0-nabors.2 -> next is .3
git -C sauron tag -l "2.85.0-nabors.3"          # empty output = free
git -C sauron rev-parse "2.85.0-nabors.3"       # errors "unknown revision" = free
```

This exact mistake already happened: firstmate was told "use x.x.x" and inferred `2.94.0` from
the tag list instead of asking; the right line was `2.85.x` (`data/learnings.md`,
"Same reflex for values the captain owns").

**A filter with its own `nabors` branch can have a version scheme with no relation to its
`main` line at all.** `altave-zones-detection@origin/nabors` `VERSION` is `2.0.0`, while its
`main`-line tags run `1.36.0`-`1.44.0` - the nabors branch restarted numbering, not continued
it, and carries no tags of its own yet. Check each filter's own `VERSION` file on its own
`nabors` branch; never assume it follows the same series as `main`.

## Where each version lives, and which one a task moves

| Location | What it means | Move it when |
|---|---|---|
| `sauron`'s own `VERSION` (repo root, `origin/nabors`) | The NABORS Sauron release version, e.g. `2.85.0-nabors.2` | Cutting a new Sauron release (image tag, git tag) |
| `sauron`'s submodule pointer (`git ls-tree origin/nabors -- filters/<name>`, a commit SHA) | Exactly which commit of that filter Sauron currently assembles | A filter has a new commit/release Sauron should pick up |
| The filter's own `VERSION` (repo root of e.g. `altave-zones-detection`, on **its own** `nabors` branch if one exists, else `main`) | That filter's own release number, independent of Sauron's | Releasing a new version of the filter itself, before Sauron points at it |

**This is the distinction that was got wrong:** "bump zones-detection on nabors" moves
`altave-zones-detection`'s own `VERSION` (on its `nabors` branch) and cuts a filter release
there, THEN updates the submodule pointer in `sauron@nabors` to that new commit. It does **not**
mean writing a stage-range number like `2.94.0` into `sauron`'s own `VERSION` - that number
belongs to a different lineage and a different repo's field entirely.

## Build and publish

Two workflows on `sauron@origin/nabors` push images and exist only there (not on `stage`):

- **`.github/workflows/push-image-ecr.yml`** - triggers automatically on `push: tags: '*-nabors.*'`
  (so pushing a `2.85.0-nabors.N` tag fires it), and also accepts `workflow_dispatch` for a
  manual run against an arbitrary `source_ref`/`dest_tag`. It builds via `docker/build-push.sh`
  reading the checked-out `VERSION` file, then re-tags and pushes `sauron-offshore:$VERSION` to
  `602234048136.dkr.ecr.sa-east-1.amazonaws.com` (default), as `sauron-offshore:<dest_tag or the
  pushed tag name>`. This is **not purely manual** - `data/projects.md`'s "manual Push Image to
  ECR workflow dispatch" line describes only the fallback path, not the tag-push trigger that
  normally fires it.
- **`.github/workflows/push-image-acr.yml`** - `workflow_dispatch` only, no automatic trigger.
  Pushes the differently-named `sauron:$VERSION` (or an explicit `image_tag` input) to
  `secrets.ACR_LOGIN_SERVER`. Note the image name changes between registries: `sauron-offshore`
  on ECR, `sauron` on ACR.

**A known fragility, not fixed here:** `docker/build-push.sh`'s deps-image step picks
`LATEST_VERSION=$(git tag --sort version:refname | tail -n 1)` - a plain sort over every tag in
the repo, nabors and stage both. Because that sort is exactly the trap this skill exists to
avoid, treat any output that depends on it as suspect on the nabors line.

`sauron@origin/nabors`'s own `create-release.yml` and `sauron-release-event-trigger.yml` are
byte-identical to `stage`'s copies - both hardcode `branches: [main]` / `branches: [stage]` and
rebase `stage` onto `main`. They are not what produces a `-nabors.N` version; nothing in this
tree was found that automates the nabors `VERSION` bump or tag creation, so treat cutting a new
`2.85.0-nabors.N` tag as a manual step until shown otherwise.

## Proving what a box is actually running

A tag string is not proof. Two different images can share the literal string
`2.85.0-nabors.2` on the same box - a registry-qualified pull and a stale local build - and a
compose file naming the bare tag silently picks whichever docker resolves locally
(`data/learnings.md`, "An unqualified image tag on a box that also pulls from ECR resolves to
the stale local copy", cost a wrong conclusion 2026-08-31).

Confirm by digest, not by tag string:

```bash
docker inspect -f '{{.Config.Image}} -> {{.Image}}' <container-or-image>
```

A mismatch looks like: the image name/tag you expect on the left, but an `.Image` (content
digest / image ID) on the right that does not match `docker inspect` of the image you just
pushed to ECR - or a second image on the box carrying the identical tag string with a different
digest. Also diff a suspicious local tag against the registry build byte-for-byte before calling
it an unreleased experiment; a descriptive local tag can be the current release under a
different name.

The known NABORS QA box is `workstation1` at `10.0.1.11`, machine-id `e3768a36`, one registered
camera (`cam0`), env file `SAURON_ENV_1.env` - every Altave edge box shares the hostname
`workstation1`, so confirm by machine-id/camera count/subnet before trusting a screenshot's
prompt (`data/learnings.md`, "Every Altave edge box is called `workstation1`").
