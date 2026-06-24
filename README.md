# IWOMP Microbenchmarking Snapshot

This repository is a clean code snapshot of the OpenMP offloading microbenchmark used for the IWOMP paper submission. It is intended to preserve the submitted code state in a compact, reproducible form.

The active development repository may continue changing after submission. This snapshot should therefore be treated as a milestone artifact rather than the latest development branch.

## What This Repository Contains

```text
.
├── Makefile
├── Makefile.defs.*
├── jobs/
├── plots/
├── result/
└── src/
```

| Path | Purpose |
|------|---------|
| `src/microbenchmark.c` | Main OpenMP target-offloading benchmark implementation. |
| `src/common.c` | Shared runtime helpers and delay-kernel implementation. |
| `src/common.h` | Declarations shared by the benchmark source files. |
| `Makefile` | Build targets for the normal and distribution-enabled benchmark binaries. |
| `Makefile.defs.*` | Compiler/toolchain-specific build flags. |
| `jobs/` | Example run scripts for the machines used during development and evaluation. |
| `plots/plot_raw_times.py` | Helper script for plotting raw timing data and fitted overhead lines. |
| `result/` | Empty output placeholder. Results are intentionally not included in this snapshot. |

## What Is Intentionally Not Included

This repository excludes generated or machine-specific artifacts:

```text
raw benchmark results
generated plots
compiled binaries
object files
temporary build directories
ad hoc test files
```

The goal is to keep only the code, build definitions, job scripts, and plotting helper needed to reproduce or inspect the submitted benchmark implementation.

## Benchmark Goal

The benchmark estimates OpenMP GPU offloading overhead by measuring total execution time across a range of artificial delay lengths. It then summarizes the measured curve using:

```text
BIC-selected linear intercept
lowest observed average time
```

The intercept is used as an estimate of launch or offloading overhead after accounting for the delay-kernel workload.

## High-Level Execution Flow

For each selected method and input size:

```text
parse command-line arguments
adjust MAX_ITER and MAX_ARRAY_SIZE if needed
check that OpenMP target execution runs on the device
generate log-spaced delay lengths
warm up the runtime/device
measure all set/run/delay combinations
write raw timing rows to raw_times.csv
fit timing curves with BIC-selected linear regression
print BIC intercept and lowest observed timing
optionally write detailed fitting output to overhead_distribution.txt
```

## Build

The default `Makefile` includes:

```make
include Makefile.defs.nvc
```

Change this line if a different compiler configuration is needed.

Available compiler definition files:

| File | Intended toolchain |
|------|--------------------|
| `Makefile.defs.nvc` | NVIDIA HPC SDK / `nvc` |
| `Makefile.defs.gcc` | GCC OpenMP offloading configuration |
| `Makefile.defs.clang` | Clang / AMD Clang-style OpenMP configuration |
| `Makefile.defs.cray` | Cray compiler environment |
| `Makefile.defs.aocc` | AOCC-style configuration |
| `Makefile.defs.MI300X` | MI300X-specific configuration |

Build the standard benchmark:

```bash
make
```

This produces:

```text
microbenchmark
```

Build the distribution-enabled benchmark:

```bash
make distribution
```

This produces:

```text
microbenchmark_distribution
```

The distribution build enables detailed per-set/per-run fitting output in `overhead_distribution.txt`.

## Run

Basic example:

```bash
./microbenchmark Method=0,1,2,3,4,5,6,7,8,9,10,11 N=16384 thread_count=32 team_count=4
```

Distribution-output example:

```bash
./microbenchmark_distribution Method=5,6,10,11 N=16384 thread_count=32 team_count=4 Delay=1,8096
```

On a batch system, the executable is usually launched from a script in `jobs/`, for example:

```bash
bash jobs/run_GH.sh
```

or submitted through the scheduler, depending on the machine-specific script.

## Runtime Parameters

All runtime parameters use `key=value` syntax.

| Parameter | Meaning |
|-----------|---------|
| `Method=` | Comma-separated list of benchmark method IDs. If omitted, all methods are run. |
| `N=` | Comma-separated list of input/mapping sizes. |
| `Delay=` | Delay range. `Delay=max` uses `[default_min, max]`; `Delay=min,max` uses the explicit range. |
| `thread_count=` | OpenMP thread limit used by methods that expose thread control. |
| `team_count=` | OpenMP team count used by methods that expose team control. |
| `MAX_ITER=` | Overrides the total kernel iteration space. |
| `MAX_ARRAY_SIZE=` | Overrides the allocated/mapped array size. |

Default values in `src/microbenchmark.c`:

```text
N_DEF              = 16382
NUM_SAMPLES        = 20
MIN_DELAYLENGTH    = 1
MAX_DELAYLENGTH    = 8096
INNERREPS          = 20
OUTERREPS          = 1
WARMUP_ITERATIONS  = 10
BENCHMARK_SETS     = 2
BENCHMARK_RUNS     = 5
MAX_ITER_DEF       = 6656
MAX_ARRAY_SIZE_DEF = 65536
```

The benchmark adjusts `MAX_ITER` and `MAX_ARRAY_SIZE` upward when required so that selected `N`, `thread_count`, and `team_count` values are covered safely.

## Method IDs

| Method | Benchmark case |
|--------|----------------|
| `0` | Pure delay kernel baseline. |
| `1` | `target map(tofrom: a)` |
| `2` | `target map(to: a)` |
| `3` | `target map(from: a)` |
| `4` | `target map(alloc: a)` |
| `5` | `target teams` scalar launch. |
| `6` | `target teams distribute parallel for` |
| `7` | `target nowait` followed by synchronization. |
| `8` | `target teams distribute parallel for` with atomic update. |
| `9` | `target teams distribute parallel for` with reduction. |
| `10` | `target teams` with explicit inner `parallel`. |
| `11` | Repeated inner `parallel` region inside `target teams`. |

Methods `1`-`4` focus on mapping behavior. Methods `5`-`11` keep data mapped and focus more on launch, teams, parallel, atomic, and reduction behavior.

## Output Files

Normal and distribution runs can produce:

```text
raw_times.csv
overhead_distribution.txt
```

`raw_times.csv` contains one row per measured data point:

```text
method_id, method_name, N, thread_count, team_count, set, run, delaylength, outerreps, exec_time_us
```

`overhead_distribution.txt` is produced when compiled with `-DPRINT_DISTRIBUTION`, usually through:

```bash
make distribution
```

It contains per-set/per-run fitting summaries such as:

```text
Set=0 Run=0 Lmin=... Intercept=... us Slope=... R2=... BIC=... Lowest=... us @ delay=...
```

## Plotting

The plotting helper can be used after a distribution run has produced both CSV and fitting text files:

```bash
python3 plots/plot_raw_times.py raw_times.csv overhead_distribution.txt 1,18 log output.png
```

Arguments:

```text
raw_times.csv              raw timing data
overhead_distribution.txt  fitted intercept/slope information
1,18                       selected delay-index range
log                        plot scale, either log or lin
output.png                 output image file
```

## Notes For Reproduction

1. Load the compiler/runtime modules required by the target machine.
2. Confirm the correct `Makefile.defs.*` file is included by `Makefile`.
3. Build with `make` or `make distribution`.
4. Run the selected methods with explicit `N`, `thread_count`, and `team_count`.
5. Move generated `raw_times.csv`, `overhead_distribution.txt`, and plots into a result directory outside this clean source snapshot.

## Contact

For questions about this snapshot or the active development version, please contact the repository owner or open an issue in the main development repository.
