# Contributing to La Roca

Thank you for your interest in contributing to **La Roca Micro-PubSub** — an
ultra-low latency, zero-allocation, lock-free Pub/Sub broker written entirely in
**x86_64 Linux Assembly** (NASM + LD, no libc).

This document defines the non-negotiable bar for any contribution: **everything
proposed must be well documented and fully tested before it is reviewed.** The
goal is to keep the engine's deterministic `O(1)` performance and its
"everything by hand, no dependencies" philosophy intact.

---

## Table of contents

- [Ways to contribute](#ways-to-contribute)
- [Before you start](#before-you-start)
- [Development environment](#development-environment)
- [Pull request process](#pull-request-process)
- [Pull Request Checklist (hard gate)](#pull-request-checklist-hard-gate)
- [Documentation guidelines](#documentation-guidelines)
- [Testing guidelines](#testing-guidelines)
- [Assembly code style](#assembly-code-style)
- [Commit conventions](#commit-conventions)
- [Code of conduct](#code-of-conduct)

---

## Ways to contribute

- **Report bugs** — memory-safety issues, protocol violations, crashes.
- **Propose features** — new endpoints, optimizations, tooling.
- **Fix issues** — start from an open issue or open one first.
- **Improve docs and tests** — clearer docs and stronger suites are always welcome.

---

## Before you start

1. **Open an issue first** for anything beyond a trivial fix. Describe the problem
   and the intended approach so it can be agreed before code is written.
2. Read the internal engineering guide: [`docs/INTERNAL_ROADMAP.md`](docs/INTERNAL_ROADMAP.md).
3. Read the register contract: [`docs/REGISTER_TOPOLOGY.md`](docs/REGISTER_TOPOLOGY.md).
   Breaking it corrupts the hot loop.
4. Read [`docs/FUZZING.md`](docs/FUZZING.md) if your change touches the L7 parser
   or router.

---

## Development environment

Required:

- `nasm` (assembly)
- `binutils` (`ld`)
- `make`, `bash`

Optional (only for specific targets):

- `gcc` — plain fuzz harness (`make fuzz`)
- `AFL++` — real guided fuzzing (`make fuzz-afl`)
- `go` — high-frequency stress benchmark (`tests/bench.go`)

Build and run:

```bash
make clean && make   # builds bin/micro-pubsub
make run             # starts the engine on port 8080
```

---

## Pull request process

1. Fork the repository and create a branch from `main`.
2. Implement the change with **inline comments** explaining the non-obvious parts.
3. Add or update **tests** as required below.
4. Add or update **documentation in `docs/`** as required below.
5. Run the full verification suite and include the results in the PR description.
6. Open the PR with a description covering: **what changed, why, and how it was
   tested**.

---

## Pull Request Checklist (hard gate)

A PR is only reviewable when **every** item below is satisfied. Reviewers should
reject PRs that skip documentation or tests, even if the code looks correct.

### 1. Documentation — mandatory

- **Every behavior, API, data-layout, or architecture change MUST be documented**
  in two places:
  - **Inline comments** in the `.asm`/`.inc`/script explaining *why* at the
    instruction/block level (not just *what*).
  - **A markdown document under `docs/`** explaining the design, rationale, and
    trade-offs at a level a newcomer can follow.
- A `docs/` document is **required** when the change:
  - alters the HTTP API contract or request parsing (`openapi.yaml`, endpoints);
  - changes a data structure, file layout, or the on-disk format;
  - changes register usage or any pinned-register contract;
  - introduces a new subsystem, build target, or operational workflow;
  - affects the performance invariants documented in `README.md`.
- The `docs/` documents must stay **consistent with the code**. If you change a
  documented behavior, update the document in the same PR.
- **Language: English only.** Comments, docs, commit messages, and test output
  must be in English.

### 2. Tests — mandatory

- **Every change must ship with tests.** A change that cannot be tested is not
  mergeable until that gap is closed or explicitly justified in the PR.
- Behavior change in the engine → add or extend a bash suite under `tests/` and
  wire it into [`tests/run_all_tests.sh`](tests/run_all_tests.sh).
- Change to the L7 parser or router → also extend `tests/corpus/` with new seeds
  and run the fuzz smoke test.
- Where practical, demonstrate the test **fails before** the fix and **passes
  after** (red-green).
- No new dependency may be introduced to the engine itself; test-only tooling is
  acceptable if it is optional and documented.

### 3. Verification — mandatory, with evidence

Run these before requesting review and paste the results in the PR:

```bash
make clean && make          # builds clean
./tests/run_all_tests.sh    # mandatory: config + e2e + security + stability
```

Additionally, depending on the change:

```bash
./tests/run_all_tests.sh --stress   # hot-path / concurrency changes
./tests/test_fuzz_smoke.sh          # parser / router changes
go vet tests/bench.go               # bench.go changes
bash -n tests/*.sh                  # shell changes
```

### 4. Performance invariants — no regressions

- Preserve the `O(1)` hot paths and the **zero-allocation / no-libc** property.
- Respect the register topology (`R12`/`R13` pinned; see
  [`docs/REGISTER_TOPOLOGY.md`](docs/REGISTER_TOPOLOGY.md)).
- If a change trades correctness for speed, state it explicitly in the PR.

---

## Documentation guidelines

- `docs/` holds process and architecture documents. Existing files:
  - [`docs/INTERNAL_ROADMAP.md`](docs/INTERNAL_ROADMAP.md) — planned low-level work and constraints.
  - [`docs/REGISTER_TOPOLOGY.md`](docs/REGISTER_TOPOLOGY.md) — canonical register contract.
  - [`docs/FUZZING.md`](docs/FUZZING.md) — fuzzing methodology and results.
- Inline comments explain *why* a block exists; `docs/` explains *how the system
  fits together*. Do not duplicate: reference the document instead of pasting it.
- Keep tables, command examples, and metrics in docs **verifiable and current**.

---

## Testing guidelines

The master orchestrator is [`tests/run_all_tests.sh`](tests/run_all_tests.sh). It
runs the mandatory suites and fails fast on the first failure:

- `tests/test_config_persistence.sh` — config & disk authority.
- `tests/test_e2e.sh` — functional & mmap logic.
- `tests/test_security.sh` — security hardening & protocol.
- `tests/test_stability.sh` — post-stress stability (concurrent hammer).

Optional stress test (requires Go):

```bash
./tests/run_all_tests.sh --stress
```

Parser fuzzing:

```bash
make fuzz                              # plain harness (smoke test)
./tests/test_fuzz_smoke.sh             # no-crash smoke test
make fuzz-afl                          # instrumented harness (real coverage)
afl-fuzz -i tests/corpus -o tests/findings -V 300 -- ./bin/fuzz_parser_afl
```

- Each new suite must be a standalone executable bash script that exits non-zero
  on failure, and must be registered in `tests/run_all_tests.sh`.
- AFL++ findings under `tests/findings/` are gitignored; never commit them.

---

## Assembly code style

- NASM, 64-bit (`elf64`), Intel syntax, no libc: kernel services via the macros
  in `src/include/syscalls.inc`.
- Comment every basic block with *why* it exists; use `;` comments, not prose
  that restates the instruction.
- Never repurpose pinned registers (`R12`, `R13`) without push/pop.
- Keep the production build byte-identical to an uninstrumented one: fuzz-only
  code must live behind conditional macros (see `docs/FUZZING.md`).
- No runtime dependencies.

---

## Commit conventions

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — new feature or endpoint.
- `fix:` — bug or memory-safety fix.
- `refactor:` — behavior-preserving change.
- `docs:` — documentation only.
- `test:` — tests only.
- `chore:` — build, tooling, or housekeeping.

Keep messages in English, imperative mood, and reference the issue when relevant.

---

## Code of conduct

Be respectful, assume good intent, and keep reviews focused on the code. No
harassment or discrimination. Maintainers reserve the right to reject
contributions that do not meet the bar above, and to ask for changes before a PR
is merged.
