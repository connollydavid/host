# host: turn a repo into an agentic project, and keep it current

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
a new host instead (step 2) — the refusal message spells out exactly how.

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

### 0. Preview

- `host-lifecycle classify <dir>` → the case (or a refusal if the target is a
  software repo — stop and follow its steps; do not adopt software in place).
- `host-lint --all` → naming tells in **live tracked files** (you will fix these).
- `host-lint --log` → tells in **history** (informational; do not rewrite unless Deep).
- Write down the **rename map** (each ordinal-named file → its content-named home
  under `plan/`) and, for case (b), the **merge plan**. Apply nothing yet.

### 1. Establish governance (by case)

- **(a)** Copy the template's `CLAUDE.md` in unchanged at the chosen revision.
  Then find the repo's implicit conventions (build, test, style) by reading the
  code or asking the human, and record them under a project-specifics heading. Do
  not impose a rule that contradicts the repo's existing style.
- **(b) (human)** Merge. For each rule in the existing `CLAUDE.md`, decide:
  *subsumed* by the spine (drop it, note it in provenance), *project-specific*
  (keep it under the project-specifics heading), or *conflicts* (stop, get a human
  ruling). Preserve any attribution or license the old file carried.
- **(c)** Upgrade: see **Upgrading** below; the ledger drives it.

### 2. Scaffold the rooms and embed the software

`host-lifecycle adopt <dir> <revision>` creates `cast/ plan/ call/` idempotently
and writes the stamp. Then embed the software in the *Where* slot as a **bare store
with worktrees**: `<name>.git/` plus the canonical worktree `<name>/` and any
parallel worktrees. Commit a `.host-software` recipe with one `[software "<name>"]`
stanza per component (URL, pinned SHA, worktree set); gitignore the trees;
materialize with `host-lifecycle software --materialize`. If the software is
already a gitlink submodule, convert it in place (preserve the pin, de-register
the gitlink, write `.host-software`, gitignore the trees), creating, moving, or
rewriting no software commit.

### 3. Wire the tools

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

**Lanes are mandatory once a spec exists; phases always.** When a component carries
a `.allium`, its CI MUST run `allium check` + `analyse` + `plan`, **every** `allium
plan` obligation MUST be dispositioned in a `<spec>.obligations` manifest (checked
by `host-lifecycle obligations <spec> --tests <dir>`), and `software --check`
HAZARDs a `.allium` with no manifest; a `.tla` MUST have a TLC lane. The lifecycle
phases above are unconditional. The full rules live in the template's `CLAUDE.md`.

The pins CI exercises directly are Rust `1.95.0` (host-lint, host-lifecycle, and
the reproducible build) and TLA+ `tla2tools v1.8.0` on Temurin `21` (the timing
lane). The requirements lane in this reference host runs on Rust `proptest`, so
`allium-cli 3.4.2` is its current-release pin rather than one this host's CI
exercises; adopt it when you wire the allium lane.

### 4. Apply the migration, in two layers

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

**Record layer: exclude, don't rewrite.** The append-only record (`MEMORY.md`,
closed milestone bodies) is history; exclude it from the audit with a
`.host-lintignore` rather than rewriting it.

### 5. Stamp and record

The stamp is already written: you wrote it when you scaffolded the rooms. Record
a `call/` decision ("adopted template @ `<revision>`") and add a `MEMORY.md`
entry, so the migration is auditable from a fresh session.

### 6. Verify

- `host-lifecycle validate plan/` and `host-lifecycle validate call/` → `ok`.
- `host-lifecycle software --check` → each worktree at its pin, no `HAZARD` (this
  also enforces the spec lanes and the `.obligations` manifest).
- For each `.allium`, `host-lifecycle obligations <spec> --tests <dir>` → every
  obligation dispositioned.
- `host-lint --all` → clean on live files (the record excluded via `.host-lintignore`).
- A throwaway commit with a tell in its message → the hook blocks it.
- If the repo ships an mdBook site, it builds.

## Upgrading

Adopting is one event; the template moves on. To upgrade, re-apply the spine
changes across the revision span *and* the **structural migrations** it introduced;
a doc diff shows the prose, not the actions. The template's `UPGRADING.md` is
the ledger of those actions, one `[upgrade "<revision>"]` stanza each.

1. Fetch the template to the target revision.
2. `host-lifecycle upgrade <dir>` prints every ledger entry **newer** than the
   repo's stamped revision (by git ancestry, so same-day revisions order right).
3. Apply each printed entry's action, in order.
4. Re-apply the spine doc changes across the span; leave project-specifics alone.
5. Re-stamp `.host` to the target revision; record it in `call/` and
   `MEMORY.md`.

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
