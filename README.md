# host: keep a repo an agentic project

Point an agent or a patient human at this one file. Follow it in order, and you
end with **an agentic project** (e.g. `agentic-acme`): a repo carrying the methodology's techniques
(the operating manual, the rooms, the verification tools) and able to **upgrade**
as the methodology moves. It is written to be literal: do each step, run the
stated check, and stop to ask the human at the points marked **(human)**.

This file is the **process**. It does not contain the techniques. Those live in
the **template**, versioned:

```
https://github.com/connollydavid/host-template
```

You copy the template's techniques in at a chosen revision and record that
revision. Later you upgrade by re-running this file against a newer one. The
template owns the techniques and the upgrade **ledger**; this file owns only the
steps that apply them.

## What you need

- `git`, and network access to the template URL above.
- The `host-lifecycle` and `host-lint` binaries (download from their GitHub
  releases, or build them). `host-lifecycle` does the mechanical work (classify,
  scaffold, stamp, number, upgrade), token-free. `host-lint` does the audit.

## Two things vary

- **Case**: what governance the repo already has (its starting state). Decides
  how you establish governance.
- **Mode**: how much you change, and whether history moves (the blast radius).
  Decides how you apply the audit.

Pick the case first, then the mode.

| Case | The repo has | You will |
|---|---|---|
| **a** | no `CLAUDE.md` | copy the canonical manual in and record the repo's own conventions |
| **b** | a `CLAUDE.md` that predates this methodology | **merge** its rules with the spine **(human)** |
| **c** | a `.host` stamp (it adopted an earlier revision) | **upgrade** by diffing template revisions |

`host-lifecycle classify <dir>` prints `a`, `b`, or `c` — **unless** the target is
itself a software repository (a root build manifest such as `Cargo.toml` /
`package.json` / `go.mod` / `pyproject.toml`, with no `.host` stamp and no
`.host-software` recipe). In that case it **refuses** (exits non-zero, prints the
steps below) rather than a case letter: a host is a *separate* meta-repo, and you
must never adopt a software repo in place. Embed the software as the Where room of
a new host instead (the *Scaffold the rooms and embed the software* step, below) —
the refusal message spells out exactly how.

| Mode | What it touches | Use when |
|---|---|---|
| **Preview** | nothing (report only) | always; run it first |
| **Shallow PR** *(default)* | one branch/PR; live files only; history untouched | almost always |
| **Staged** | several PRs; live files only | the live diff is too large to review in one PR |
| **Deep rewrite** | history (archive-first, force-push) | only when history coherence is worth more than its provenance |

**Selection rule.** Default to **Shallow**. Go to **Staged** when the live diff is
too big to review in one sitting. Choose **Deep** *only* when rewriting history
buys coherence worth more than the disruption, and **never** on history carrying
provenance you do not control (an upstream patch series, tags others have pulled).
Deep always means: push a protected `archive/` branch first, then rewrite, then
force-push with lease. History is **immutable by default**; outside Deep, tells in
the log are *acknowledged*, not rewritten.

## The stamp: `.host`

A host records which template revision it adopted, at the repo root:

```
template = "https://github.com/connollydavid/host-template"
revision = "<sha-or-tag>"
adopted  = "YYYY-MM-DD"
```

`host-lifecycle adopt` writes it; `host-lifecycle version` reads it. The
`revision` is what a later case-(c) upgrade diffs from, so it must be exact.

## The procedure

### Preview

- `host-lifecycle classify <dir>` → the case (or a refusal if the target is a
  software repo — stop and follow its steps; do not adopt software in place).
- `host-lint --all` → naming tells in **live tracked files** (you will fix these).
- `host-lint --prose` → **prose tropes** in authored docs (the LLM-slop markers it
  flags). You will clean these to zero, the way you clear naming tells.
- `host-lint --log` → tells in **history** (informational; do not rewrite unless Deep).
- Write down the **rename map** (each ordinal-named file → its content-named home
  under `plan/`) and, for case (b), the **merge plan**. Apply nothing yet.

### Establish governance (by case)

- **(a)** Copy the template's `CLAUDE.md` in unchanged at the chosen revision.
  Then find the repo's implicit conventions (build, test, style) by reading the
  code or asking the human, and record them under a project-specifics heading. Do
  not impose a rule that contradicts the repo's existing style.
- **(b) (human)** Merge. For each rule in the existing `CLAUDE.md`, decide:
  *subsumed* by the spine (drop it, note it in provenance), *project-specific*
  (keep it under the project-specifics heading), or *conflicts* (stop, get a human
  ruling). Preserve any attribution or license the old file carried.
- **(c)** Upgrade: see **Upgrading** below; the ledger drives it.

### Scaffold the rooms and embed the software

`host-lifecycle adopt <dir> <revision>` creates `cast/ plan/ call/` idempotently
and writes the stamp. Then embed the software in the *Where* slot as a **bare store
with worktrees**: `<name>.git/` plus the canonical worktree `<name>/` and any
parallel worktrees. Commit a `.host-software` recipe with one `[software "<name>"]`
stanza per component (URL, pinned SHA, worktree set); gitignore the trees;
materialize with `host-lifecycle software --materialize`. If the software is
already a gitlink submodule, convert it in place (preserve the pin, de-register
the gitlink, write `.host-software`, gitignore the trees), creating, moving, or
rewriting no software commit.

Every worktree **must** surface *under* the host root — never a bare external
path. When a backing store has to live elsewhere (another filesystem or platform,
e.g. a native-Windows build that cannot sit on a WSL share), record it on the
parallel line as `worktree = <dir> <branch> <pin> store=<path> [host=<os>]`:
`--materialize` realises the store at `<path>` and the in-tree `<dir>` as a
symlink/junction to it, so an edit through `<dir>/…` still lands in the tree under
test. `host=<os>` (optional) is the OS that *materializes* the store — where you run
`host-lifecycle` — not the build platform; a Windows Dev Drive reached from WSL is
`host=linux`. `software --check` HAZARDs any worktree path that escapes the root.

### Wire the tools

Add the four verification tools as submodules (reference, do not vendor: each is
pinned to a commit), then **generate** their skill symlinks with `link-skills.sh`
after materialization (do not git-track a symlink into a path that a fresh clone
has not materialized). allium, specula and host-lifecycle each ship Claude skills
under `skills/`, so an agent drives them through those skills — not from memory:

```
tools/host-lint        github.com/connollydavid/host-lint        (Rust)
tools/host-lifecycle   github.com/connollydavid/host-lifecycle   (Rust)
tools/allium           github.com/juxt/allium                    (Rust CLI + agent skill)
tools/specula          github.com/specula-org/Specula            (TLA+, runs on the JVM)
tools/host-prove       github.com/connollydavid/host-prove       (deep-verification rungs; opt-in)
```

The submodule gives you a tool's specs and its driver, not the **binary
component** that runs them. Two of the four are pure Rust binaries; the other two
carry a runtime you install separately. Pin the exact versions below: they are the
set this methodology is verified against. Install each:

- **host-lint, host-lifecycle** (hygiene + lifecycle): the two Rust binaries from
  "What you need". Build with `cargo build --release` in each submodule under Rust
  `1.95.0` (the digest-pinned `rust:1.95.0` container is the reproducible-build
  anchor; CI builds in it), or download a release. Then install the `host-lint`
  git hooks with `host-lifecycle software --install-hooks .` (copies `pre-commit`,
  `commit-msg`, and the built binary) so new commits are gated from here on.
- **host-lifecycle skills**: `tools/host-lifecycle` also ships one skill per
  lifecycle phase — `classify`, `adopt`, `embed`, `remap`, `verify`, `publish`,
  `upgrade` — wired by the same `link-skills.sh`. Drive each phase through its
  skill and command; the phases are **unconditional** (no opt-out).
- **allium** (requirements lane, behavioural specs / property-based): its skills
  (`elicit`/`distill`/`tend`/`weed`/`propagate`) come from the `tools/allium`
  submodule via `link-skills.sh` — author and maintain `.allium` through them, not
  by hand (Claude Code users may instead `/plugin install allium`). The `.allium`
  specs are checked by the `allium` CLI: `cargo install allium-cli@3.4.2`, or
  `brew tap juxt/allium && brew install allium`.
- **specula** (timing and concurrency lane, TLA+): its TLA+ workflow skills also
  come from the `tools/specula` submodule. The `.tla` specs are model-checked by
  TLC, a Java tool: install a Temurin `21` JDK and `tla2tools.jar` `v1.8.0` from
  the `tlaplus/tlaplus` releases, then run `java -cp tla2tools.jar tlc2.TLC -config
  <spec>.cfg <spec>.tla`. CI runs exactly these versions (`actions/setup-java`
  Temurin `21` plus the pinned `v1.8.0` jar); see the Specula workflow.
- **host-prove** (deeper rungs, **opt-in**): above the bounded lanes, `tools/host-prove`
  drives three heavier verifiers as skills — **Apalache** (symbolic/parametric TLA+ via
  SMT), **TLAPS** (`tlapm`, unbounded proof; authoring needs a strong model), and a
  target-specific **code-conformance** verifier (Rust → **Kani**). Each skill turns the
  tool's output into one machine-readable verdict, so a rung runs down to a small model.
  Wire the submodule and `link-skills.sh` only when you declare a rung by dispositioning
  an obligation `kani:`/`apalache:`/`tlaps:`. Verifiers install from official prebuilt
  binaries pinned by version + SHA256 (no Docker).

**Lanes are mandatory once a spec exists; phases always.** When a component carries
a `.allium`, its CI MUST run `allium check` + `analyse` + `plan`, **every** `allium
plan` obligation MUST be dispositioned in a `<spec>.obligations` manifest (checked
by `host-lifecycle obligations <spec> --tests <dir>`), and `software --check`
HAZARDs a `.allium` with no manifest; a `.tla` MUST have a TLC lane. A declared
deeper rung is the same rule one level up: an obligation dispositioned
`kani:`/`apalache:`/`tlaps:` MUST have its CI lane (`cargo kani` / `apalache-mc` /
`tlapm`) or `software --check` HAZARDs it — but only once declared; the rungs are
opt-in and inert otherwise. The lifecycle phases above are unconditional. The full
rules live in the template's `CLAUDE.md`.

The pins CI exercises directly are Rust `1.95.0` (host-lint, host-lifecycle, and
the reproducible build) and TLA+ `tla2tools v1.8.0` on Temurin `21` (the timing
lane). The requirements lane in this reference host runs on Rust `proptest`, so
`allium-cli 3.4.2` is its current-release pin rather than one this host's CI
exercises; adopt it when you wire the allium lane.

### Apply the migration, in three layers

**Live layer: rename with the dictionary.** Turn the rename map into a
`.host-remap` dictionary (`old => new` per line). `git mv` each ordinal-named file
to its content-named home, then `host-lifecycle remap --check <dir>` until clean
(disposition each remaining tell: a dictionary entry, a `.host-lint-allow` entry
for genuine vocabulary, or an excluded path). Commit (the clean tree is the
verbatim archive), then run `host-lifecycle remap --apply <dir>`, which makes only
the declared substitutions, map-only by construction. Commit, then `git rm .host-remap` (its
durable copy goes in the `call/` decision). Shallow: one PR. Staged: split
governance → tooling → bulk rename. Deep (human): archive-first, then rewrite
history too.

**Prose layer: clean the slop.** `host-lint --prose` flags the LLM-slop prose tropes
(decoration dashes and arrows, tricolons, and the rest) in authored docs. Reword them
to plain prose so the docs read as written, not generated: **zero tropes**, the same
bar as the naming audit. The append-only record is excepted (below).

**Record layer: exclude, don't rewrite.** The append-only record (`MEMORY.md`, closed
milestone bodies) is history, and `MEMORY.md` is the **agent's own working memory**;
exclude it from both the naming audit and the prose audit with a `.host-lintignore`,
rather than rewriting it.

### Stamp and record

The stamp is already written: you wrote it when you scaffolded the rooms. Record
a `call/` decision ("adopted template @ `<revision>`") and add a `MEMORY.md`
entry, so the migration is auditable from a fresh session.

### Verify

- `host-lifecycle validate plan/` and `host-lifecycle validate call/` → `ok`.
- `host-lifecycle software --check` → each worktree at its pin, no `HAZARD` (this
  also enforces the spec lanes and the `.obligations` manifest).
- For each `.allium`, `host-lifecycle obligations <spec> --tests <dir>` → every
  obligation dispositioned.
- `host-lint --all` → clean on live files (the record excluded via `.host-lintignore`).
- `host-lint --prose` → **zero prose tropes** in authored docs (the agent's `MEMORY.md` excepted).
- A throwaway commit with a tell in its message → the hook blocks it.
- If the repo ships an mdBook site, it builds.

## Upgrading

Adopting is one event; the template moves on. The `.host` stamp records **what you
have applied**: a `baseline` ledger entry (every entry at or before its position in
`UPGRADING.md` counts applied) plus an optional `applied` set of entries taken out of
order. The template's `UPGRADING.md` is the ledger of actions, one `[upgrade
"<revision>"]` stanza each, ordered by file position; a stanza may declare
`independent`/`depends` and a `verify` post-condition.

1. Fetch the template to the target revision.
2. `host-lifecycle upgrade <dir>` lists every ledger entry **not yet applied**, by
   ledger position (never git ancestry). A legacy single-`revision` stamp is migrated
   once to a `baseline`. `upgrade --next` prints the single next safe action.
3. Apply an entry, then record it: `host-lifecycle upgrade --record <id>` (id,
   unambiguous prefix, or ledger ordinal). The tool validates the id, refuses if a
   `depends` is unapplied, runs the entry's `verify` — or requires `--unverified
   call/NNNN` when it has none — and appends an append-only claim. **Never hand-edit
   the stamp.** A late `independent` entry may be cherry-applied without an earlier
   unrelated one; deferred entries stay pending and re-list (fail-safe), and
   `upgrade --advance` later compacts a contiguous applied run into the `baseline`.
4. Re-apply the spine doc changes across the span; leave project-specifics alone.
5. `host-lifecycle software --check` re-checks every recorded claim; record the
   upgrade in `call/` and `MEMORY.md`.

The ledger lives with the techniques that generate it, in the template. This file
does not change when the template adds an entry; only the template does.

## Notes

- **Idempotent and resumable.** `adopt` skips rooms that exist. If interrupted,
  re-run `classify` and continue.
- **Token-free where mechanical.** `host-lifecycle` scaffolds, numbers, stamps,
  and runs the dictionary `remap`; `host-lint` audits. Spend model effort only on
  the judgment: the case-(b) merge, eliciting case-(a) conventions, naming each
  milestone, and audit triage. The substitutions are deterministic.
- **Repo-root config the tools read.** `.host-software` (the *Where* recipe),
  `.host` (the stamp), `.host-remap` (the rename dictionary, transient),
  `.host-lint-allow` (sanctioned vocabulary), `.host-lintignore` (excluded paths).
  All are plain line-oriented files.
