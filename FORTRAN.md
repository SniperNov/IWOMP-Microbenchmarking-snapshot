# Fortran OpenMP target-offload microbenchmark

Complete Fortran translation of `src/{common.c,common.h,microbenchmark.c}` from the preserved research snapshot `85eddd9`. The original C files remain unchanged. The Fortran files now live in the same `src/` directory and use the same root Makefile as C.

## Build and run

```sh
make check                          # GNU host functional verification first
make BENCH_LANG=fortran              # GNU Fortran build
make COMPILER=nvfortran distribution  # Rebuild for the NVIDIA GPU toolchain
OMP_TARGET_OFFLOAD=MANDATORY ./microbenchmark_distribution \
  Method=0,5,6,7,10 N=16384 Delay=1,8096 thread_count=32 team_count=4
```

Selecting Fortran without a compiler chooses GNU Fortran with `-O0`, OpenMP and preprocessing. `COMPILER=nvfortran` or `FC=nvfortran` automatically selects the supplied GPU Fortran profile. Choose `CONFIG=Makefile.defs.gfortran` or `Makefile.defs.nvfortran` explicitly if preferred. The root `make` default remains C for compatibility; all examples in this section select Fortran explicitly. `make check` leaves GNU Fortran executables at the shared root paths; rebuild with your production compiler after verification, as ordered in the example above.

Both source files use the same compilation flags, and `common.f90` is compiled before `microbenchmark.F90` to supply its module interface. Generated modules are isolated by normal/distribution/check mode under `.build/fortran/`. Free-format sources are under 132 columns; the GPU profile uses `-Mpreprocess -Mfree`, with `-module` for module output, as specified in the [NVIDIA compiler reference](https://docs.nvidia.com/hpc-sdk/compilers/hpc-compilers-ref-guide/). The GNU profile uses `-cpp` and `-J` ([GNU module-directory options](https://gcc.gnu.org/onlinedocs/gfortran/Directory-Options.html)).

GNU builds need an installed offload backend and its architecture flags to execute on a GPU. NVHPC commands are generated and checked locally, but no NVHPC compiler/GPU is installed here. See the root [README.md](README.md) for language auto-detection, custom profiles and shared targets.

By default the executable exits before measurement if the target runs on the host, matching the C snapshot. `--allow-host` explicitly enables functional smoke testing on a CPU and prints a warning. Do not use those timings as offload measurements. A zero-device environment defaults to one team so that this smoke-test mode has a valid configuration.

Arguments retain `Method`, `N`, `Delay`, `thread_count`, `team_count`, `MAX_ITER`, and `MAX_ARRAY_SIZE`, with comma-separated configuration lists. `Delay=max` means `[1,max]`; reversed bounds are sorted. Unknown options, invalid methods, empty lists, nonpositive sizes, equal delay endpoints, and unsafe sizes are rejected before measuring. The original defaults, including N=16382, are retained.

`raw_times.csv` is replaced; `overhead_distribution.txt` is appended. Output CSV columns and detailed fit text remain compatible with the C plotting helper in `plots/plot_raw_times.py`. Configuration results are printed one per line with explicit thread/team labels.

## Benchmark semantics

| Method | Measured construct |
| --- | --- |
| 0 | target with scalar delay kernel |
| 1–4 | target with tofrom/to/from/alloc mapping of N doubles |
| 5 | target teams; one delay kernel per team |
| 6 | target teams distribute parallel do over MAX_ITER |
| 7 | target nowait followed immediately by taskwait |
| 8 | distributed parallel delay kernels and atomic updates into N elements |
| 9 | distributed parallel delay kernels and array reduction into N elements |
| 10 | target teams containing a separate parallel region |
| 11 | target teams containing N repeated parallel regions |

Methods 1–4 include mapping in the measured interval. All other methods map the full array and temporary storage in an enclosing target data region outside the timer. Each point averages 20 launches, including the original host-side increment. Warm-up runs the full 20-point sweep ten times. Real measurements use two sets of five runs and one outer repetition. Twenty logarithmic delay points, the unsigned-32-bit LCG Fisher–Yates order, and its set/run seeds are retained. Delay kernels receive integers truncated at the device call, while CSV labels round and regression uses the original floating-point delay, just as in C. Host sampling calls the standard C math-library `log2` and `pow` through `ISO_C_BINDING`, in the original expression order, so geometric points close to integer boundaries do not lose an iteration through a different Fortran logarithm expression. No original C source is linked into the benchmark. Zero-based array bounds preserve C index formulas.

For each run the code tries suffix linear fits retaining at least ten points and chooses the smallest original BIC formula `n*log(RSS/n)+2*log(n)`. It averages the ten intercepts and separately the ten per-run minima, with sample standard deviations. This preserves the snapshot's estimator, including comparisons of BIC over different suffix sizes; it does not change it into the methodology described in the paper. Fits with nonpositive denominator or RSS are skipped, as in C.

## Compiler branches and translation choices

This translation follows the combined Method 6 loop shared by the NVHPC and Clang/Cray/AMD branches, and the combined Method 9 reduction in the NVHPC branch and paper pseudocode. Those C NVHPC branches are valid; this translation does not establish that existing measurements were wrong and does not change the preserved C files.

The exact saved C file has no Method 6/9 branch for plain GCC, and the alternate Method 9 branch has two pragmas without `omp`. These are conditional observations about this source revision. The Fortran combined Method 9 is not a byte-for-byte reproduction of the alternate branch's ignored-pragmas behavior. Comparing to AMD/Clang measurements requires checking the source and compiler actually used for those runs. See [AUDIT.md](AUDIT.md) for evidence and scope.

* Host arrays are initialized once outside measurement; C uses uninitialized `malloc` storage. This initialization is documented, not claimed to repair a measured failure.
* Device code uses firstprivate local copies of workload/array-size configuration. The device delay routine performs the original loop and negative-value observation.
* The array dummy has explicit shape and zero-based bounds. GNU Fortran lowering verifies this removes extra offset/stride metadata mappings that the first assumed-shape translation introduced inside target regions.
* Method 10 keeps the C floor-stride formula. The original maximum-array-size adjustment already guarantees enough space for all requested teams and threads; no additional stride policy is imposed.
* All original teams/thread clauses are retained. No `num_threads` is added, and Methods 8/9 keep the C absence of `num_teams`/`thread_limit`. Therefore their CSV thread/team labels describe the requested configuration, not an enforced device configuration. `thread_limit` supplies a ceiling, not an exact thread count.
* The timer includes target launch, existing-map lookup, scalar argument setup, kernel, synchronisation and the original host increment. Pre-mapping removes full array transfer from the interval for Methods 0 and 5–11; it does not imply zero mapping-management overhead. The Fortran reduction descriptor and compiler-generated clause temporaries may add implementation bookkeeping relative to C.

Compilation and CPU smoke tests cannot validate device execution, GPU performance, or cross-compiler reduction implementation. Run the suite with mandatory offload on the intended system before using it for GPU comparisons. Reuse/licensing terms follow the original target snapshot, which has no separate license declaration; this translation adds no new license.

## Local verification

Validated with GNU Fortran/GCC 14.2.0 on a machine with no GPU. `make check` builds the ordinary and distribution executables at `-O0`, and the checked build with `-fcheck=all -Wall -Wextra`, then runs:

* `tests/smoke.py`: all twelve methods in both checked and distribution executables (2,400 samples each), independent BIC/minimum statistics, argument validation and default host guard.
* `tests/build.py`: explicit/automatic language selection, conflicting inputs, environment choices, parallel builds, repeated language switches, module isolation, changed flags and relative compiler paths. Runs in a temporary source copy.
* `tests/semantics.py`: final kernel arrays from C versus Fortran for all twelve methods, two N values, two thread counts and two team counts varied independently (96 cases); every atomic/reduction bucket; exact samples and truncated delay lengths for three ranges including an integer-boundary case. Uses GNU C with the NVHPC source branch selected, not the NVHPC compiler. Temporary copies inspect reduction state after the timer; production code has no added checks inside timing. Small harness-controlled workloads make this a functional test, not an experiment.

Test compiler overrides: `TEST_FC` and `TEST_CC` (defaults `gfortran` and `gcc-14`). Temporary test outputs do not replace experiment files. GPU map direction, actual teams/thread counts and device timings still require verification on the intended device/toolchain.
