# MORK

Julia port of [trueagi-io/MORK](https://github.com/trueagi-io/MORK) —
the high-performance PathMap trie substrate for Hyperon/MeTTa systems.

## Status

**Phase 1-3 complete.** PathMap substrate (all zipper variants, lattice
algebra, morphisms, arena compact, serialization) + mork_expr (encoding,
traversal, unification, apply) + mork_interning + mork_frontend (sexpr,
JSON parsers) + mork_kernel (Space, Sources, Sinks, Pure, metta_calculus).

1555 unit tests pass. 8/8 integration tests from upstream `main.rs` pass
(lookup, positive, positive_equal, negative, bipolar, top_level,
two_positive_equal, two_positive_equal_crossed).

## Development Workflow

**Start once, stay warm forever.** Revise auto-reloads `src/` on every save.

```bash
# Start once per session (~15s load, then instant forever)
cd /tmp/mork-repo
julia --project=. -i tools/mork_repl.jl
```

Inside the REPL:
```julia
t()                    # run full test suite (1555 tests, ~50s first run, instant after)
t("test/my_test.jl")   # run specific test file
mc("(exec 0 (, foo) (, bar))\nfoo\n")  # eval s-expr interactively
```

Edit any file in `src/` → Revise reloads it automatically. No restart needed.

**Note:** Revise cannot reload struct redefinitions (type changes).
For those, restart the REPL once. All function-body changes reload instantly.

**Before every commit: cold-start verification.**

```bash
echo 't()' | julia --project=. tools/mork_repl.jl
```

**Use `include()` from the REPL, not piped stdin.** Piping multiline
commands splits them into individual REPL lines, breaking string literals
that contain newlines. Write test logic to `/tmp/name.jl` and `include()`
it from the warm REPL.

## Status

## Scope

1:1 parity port across upstream's `main` and `server` branches. Covers:

- Byte-tag expression encoding (`expr/`)
- PathTrie substrate storage + kernel operations (`kernel/`)
- Frontend parsers (sexpr, cz2, cz3, he, json) (`frontend/`)
- HTTP server (1:1 with upstream `server/` crate) (`server/`)
- Julia client mirroring upstream's `python/client.py` (`client/`)
- Distributed scaling via Dagger.jl + MPI (`distributed/`) — PRIMUS extension
  beyond upstream's single-process model

## Principles

- **Zero PRIMUS dependencies.** Standalone package, depends only on
  stdlib + minimal Julia ecosystem libs.
- **Metagraph-first substrate.** No Vector-typed atom/byte/tensor storage.
  See `feedback_no_vector_metagraph_first.md`.
- **Generic library.** No domain hardcoding; users decide namespace
  topology at runtime. Figure 4 (App + Common Atomspace per Hyperon WP
  §9) is a user-level example in `examples/`, not library code.
- **Practical auxiliary indices.** Small Dict-based indices for hot paths
  (type lookup, session state) are fine; matches upstream's own
  `HashMap` usage. Strict "trie-only" is rejected as unnecessary cost.

## Package Layout

```
src/
├── MORK.jl             # top-level module
├── expr/               # Tag, ExprSpan, ExprEnv, Apply, ContentAddressing
├── kernel/             # PathTrie, Space, Algebra, SpaceTemporary, Sinks, Sources, Pure
├── frontend/           # SExpr, Cz2Parser, Cz3Parser, HeParser, JsonParser, RosettaParser
├── server/             # Server, Commands, ResourceStore, ServerSpace, StatusMap
├── distributed/        # DistributedPathTrie, DaggerIntegration, Sharding
├── client/             # Client
└── runtime/            # ZipperVM, Interpreter, Reflection

test/
├── runtests.jl
├── server_tests.jl
└── distributed_tests.jl

examples/
└── multi_domain_demo.jl    # Figure 4 user-level example
```

## Relationship to Other PRIMUS Packages

MORK is a **foundation** package. Other PRIMUS packages may depend on MORK,
but MORK depends on zero PRIMUS packages.

- `PRIMUS_Metagraph` will eventually compose `MORK.Space` rather than
  duplicate the substrate (Phase 7 of the migration).
- `tools/metta_server.jl` may optionally layer on top of `MORK.server`.

## Upstream Reference

Pinned at: `~/JuliaAGI/dev-zone/MORK` (both `main` and `origin/server`
branches). Every module in this package has a diff comment referencing
the upstream Rust source it ports from.
