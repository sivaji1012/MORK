# Contributing to MORK.jl

## Development Setup

```julia
using Pkg
Pkg.develop(path = ".")
Pkg.test("MORK")
```

## Warm REPL Workflow (recommended)

```bash
# Start once per session (~60s first load, then instant)
julia --project=. -i tools/mork_repl.jl

# Inside the REPL:
t()                          # run full test suite (1566 tests)
t("test/integration/bc0.jl") # run a specific test
mc("(exec 0 (, foo) (O bar))\nfoo")  # eval s-expressions
```

Edit any file in `src/` and Revise reloads it automatically — no restart needed.

## Running Benchmarks

```bash
julia --project=. benchmarks/benchmarks.jl
julia --project=. benchmarks/benchmarks.jl --tune   # full calibration
```

## Cold-Start Verification

```bash
printf 't()\n' | julia --project=. tools/mork_repl.jl
```

## Running Examples

```bash
julia --project=. examples/transitive_closure.jl
julia --project=. examples/aggregation.jl
julia --project=. examples/backward_chaining.jl
```

## Static Linting

```bash
bash tools/lint.sh   # 4 checks: oz.loc doubles, ez.loc, sub_ez bounds, step-cap
```

## Registering a New Release

MORK.jl uses [Registrator.jl](https://github.com/JuliaRegistries/Registrator.jl).

1. Update `version` in `Project.toml`
2. Commit and push to `main`
3. Comment `@JuliaRegistrator register` on the commit on GitHub
4. Registrator opens a PR to [JuliaRegistries/General](https://github.com/JuliaRegistries/General)

## Package Info

| Field | Value |
|-------|-------|
| Name | `MORK` |
| UUID | `162375cb-4023-4ef9-895b-22c0041d5c13` |
| Repo | `https://github.com/sivaji1012/MORK.git` |
| Min Julia | `1.10` |
