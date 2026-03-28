# ctf — clang-tidy per module

<p align="center">
  <img src="resources/logo-512.png" alt="ctf icon" width="512" />
</p>

Runs `clang-tidy` on groups of source files defined in `ctf.toml`. Each group (module) can have its own paths, file patterns, and flags. Supports parallel execution.

## Installation

```sh
# via Nix flake
nix profile install .

# or manually (requires Zig 0.15)
make install PREFIX=~/.local
```

## Usage

```sh
ctf list                          # show all modules
ctf run all                       # run all modules
ctf run ACd                       # run one module
ctf run ACd --jobs=8              # override parallelism
ctf run ACd --fix                 # apply fixes
ctf run ACd --dry-run             # print files, don't run
ctf run ACd --filter="*.cpp"      # only files matching pattern
ctf run ACd --flags="--checks=*"  # override all flags for this run
ctf run ACd --file=other.toml     # use a different config file
```

CLI flags take priority over `ctf.toml` values. `--flags` overrides both global and module flags entirely.

## ctf.toml

```toml
[config]
# Path to clang-tidy binary (default: "clang-tidy")
clang-tidy = "clang-tidy"

# Base flags applied to every module. Module flags are concatenated after these.
# --checks:               which checks to run (avoid clang-analyzer-* — it's slow)
# --warnings-as-errors:   treat matched warnings as errors
clang-tidy-flags = "--checks=bugprone-*,performance-*,readability-* --warnings-as-errors=*"

# Path to compile_commands.json — required for correct include resolution
compile-commands = "build/compile_commands.json"

# Number of files to process in parallel (each gets its own clang-tidy process).
# jobs=1 passes all files to a single clang-tidy invocation.
# jobs=N spawns N processes concurrently and buffers output per file.
jobs = 8

fix     = false
dry-run = false


[modules]

# Each module is [[ModuleName]] with its own paths, file patterns, and optional flags.
# Paths are non-recursive — list every directory explicitly.
# Module clang-tidy-flags are appended to the global flags above.

[[AM1]]
path  = ["src/AM1/AMSM1", "src/AM1"]
files = "*.cpp,*.c"
# --header-filter limits which headers generate warnings.
# Without it clang-tidy reports warnings from all included headers (Qt, stdlib, etc.)
# which produces noise and slows down analysis significantly.
clang-tidy-flags = "--header-filter=src/AM1/.*"

[[AM2]]
path  = ["src/AM2"]
files = "*.cpp,*.c"
clang-tidy-flags = "--header-filter=src/AM2/.*"

[[UI]]
path  = ["src/UI", "src/UI/widgets"]
files = "*.cpp"
clang-tidy-flags = "--header-filter=src/UI/.*"
```

### Performance notes

| Setting | Impact |
|---|---|
| `files = "*.cpp,*.c"` only, no `*.h` | Headers are checked via their including `.cpp` — listing them directly duplicates work |
| `--header-filter=src/MyModule/.*` | Without this clang-tidy emits warnings from every included header (Qt, Boost, stdlib). A single file can produce 80k+ suppressed warnings and slow the run significantly |
| `--checks=bugprone-*,performance-*` | `clang-analyzer-*` is an order of magnitude slower; enable only when needed |
| `jobs = N` (N ≈ CPU count) | Each file runs as an independent clang-tidy process; near-linear speedup up to I/O saturation |
| `compile-commands` | Required — without it clang-tidy cannot resolve includes and will miss real issues |

### Flag priority

```
--flags (CLI)  >  global clang-tidy-flags + module clang-tidy-flags
```

When both global and module flags are set they are concatenated:

```
"--checks=bugprone-*" + " " + "--header-filter=src/Foo/.*"
```

`--flags` on the CLI replaces both entirely.
