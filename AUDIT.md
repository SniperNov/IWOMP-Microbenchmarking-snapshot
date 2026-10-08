# C/Fortran benchmark audit

Reviewed on 7 October 2026 against the preserved `src/microbenchmark.c` and `src/common.c`. Changes live on `codex/fortran-target`; C sources and the `main` commit remain unchanged. This is an audit of this snapshot, not a validation or rejection of historical measured results.

## Mapping and kernel timing

| Methods | C timer/data placement | Fortran translation | What the interval means |
| --- | --- | --- | --- |
| 1–4 | Start before 20 target regions; each maps N elements tofrom/to/from/alloc; stop after loop | Same placement and directions; no enclosing target-data mapping | Mapping + launch + delay kernel + host increment; not pure transfer time |
| 0, 5–11 | Allocate/zero tmp, enter target data mapping full a and N tmp outside timer; 20 target launches; stop before data exit | Same allocation/data/timer sequence | Launch + kernel + synchronization; bulk array transfer is outside timer, runtime map lookups remain |
| 7 | nowait immediately followed by taskwait inside each repetition | Same | Measures completion, not merely asynchronous submission |
| 8/9 | Delay one unique a element per loop iteration; increment tmp(i%N) atomically or by reduction | Same indexing, modulo and combined reduction semantics | Includes atomic/reduction work; reduction-private storage and merging belong in the interval |

Both languages execute the host `a[0] += 1` inside the timer. With separate device memory this does not update an already-mapped device element automatically; the next target invocation retains device data. No extra `target update` was added. Timings are host-observed through `omp_get_wtime`, divided by 20 and converted to microseconds.

The original first Fortran port used assumed shape `a(0:)`. GNU Fortran's `-fdump-tree-omplower` showed implicit `map(to:offset [len:8])` on measured targets. The revised `a(0:g_max_array_size-1)` removes those offset/stride mappings. Inner implicit full-array mappings cover the same storage already held by `target data`, with no `always` modifier. They reuse existing mappings under OpenMP reference-count rules; entering the target still incurs mapping-management work. GNU lowering retains small `num_teams`/`thread_limit` expression mappings and the allocatable reduction descriptor. Consequently, source timing isolation is preserved, but equal C/Fortran runtime bookkeeping is not asserted. No GPU transfer trace has been obtained locally.

OpenMP reference: [map-clause semantics](https://www.openmp.org/spec-html/5.1/openmpsu119.html) and [implicit data-mapping rules](https://www.openmp.org/spec-html/5.2/openmpsu60.html). Device profiling with the actual compiler/runtime is required to confirm transfer reuse on the GPU.

## Teams, threads and independence

| Method | Clauses retained from C | Index/workload retained | Isolation boundary |
| --- | --- | --- | --- |
| 0–4, 7 | No teams/thread clauses | One delay kernel per target invocation | Input thread/team lists do not control the kernel |
| 5 | num_teams(team_count); no thread_limit or parallel | team_id * array_size / requested_team_count | One initial thread runs each team body; requested threads has no clause effect; work grows with actual teams |
| 6 | num_teams(team_count), thread_limit(thread_count) | Loop over global MAX_ITER; unique a(i) | Counts controlled separately, but actual counts are runtime decisions |
| 8/9 | No num_teams/thread_limit | Loop over global MAX_ITER; tmp(i%N) | Thread/team inputs are not enforced on these methods |
| 10 | target teams with both clauses, separate parallel | team_id * floor(array_size/team_count) + thread_id | Distinct array positions; total delay work grows with actual teams × threads |
| 11 | Same teams clauses; N separate parallel regions | (team_id * requested_thread_count + thread_id) % array_size | Distinct positions, repeat count N; work grows with counts × N |

`thread_limit` is an upper bound; it is not `num_threads`. Adding `num_threads` or missing clauses to Methods 8/9 would change the benchmark, so none were added. The tests vary teams and threads independently to check translation, but the experimental design does not universally isolate their overhead from kernel work.

The C adjustment is also retained: `MAX_ITER >= max(6656, max N, max requested threads*teams)` and `MAX_ARRAY_SIZE >= max(65536, max N, max requested threads*teams)`, applied once across all configuration lists. Thus a sufficiently large N or count sweep can increase the common workload/mapping size. Separate invocations may have different workloads. This coupling belongs to the snapshot and was not silently removed. Because `array_size >= threads*teams`, Method 10's floor stride is sufficient and Method 11's modulus does not collide for the requested limits. Actual runtime count limits still need device validation.

OpenMP reference: [teams semantics](https://www.openmp.org/spec-html/5.2/openmpse58.html), [thread_limit semantics](https://www.openmp.org/spec-html/5.2/openmpse80.html).

## Methods 6 and 9: qualified findings

* C's default `Makefile.defs.nvc` uses `nvc -mp=gpu -O0`. Its Method 6 and Method 9 branches contain the valid combined loop and combined array reduction. These are represented in Fortran by `parallel do` and whole-array `reduction(+:tmp)`.
* Method 6's Clang/Cray/AMD branch has the same valid directive. The COSMA5 Method 6 script examined in the research workspace uses ROCm Clang `-O0`; this source branch does not have the plain-GCC fall-through caveat.
* Only the saved alternate Method 9 branch has `#pragma teams` and `#pragma parallel` without `omp`. Local Clang syntax checking reports them as ignored. This observation does not identify which source revision was used for the user's actual measurements.
* The Fortran Method 9 follows the combined NVHPC branch. It does not claim equivalent runtime behavior to the alternate snapshot branch with ignored pragmas. No C branch was rewritten.

The previous general description of Methods 6/9 as “repairs” was too broad and has been removed. No inference about the validity of the user's measurement results follows from this audit alone.

## Corrections to the first Fortran translation

1. Default build optimization changed from -O2 to -O0, matching every supplied C configuration and the local experimental-methodology text. The delay loop is preserved.
2. Explicit-shape input removes measured array offset/stride metadata mapping introduced by the first port.
3. Float-to-integer delay conversion moved back inside the device call, matching C's argument conversion and transferred scalar type.
4. Host log2/pow sampling and ratio order now match C. The first expression could truncate a geometric point such as 24 to 23 for `Delay=3,1572864`.
5. Degenerate BIC initializes to positive infinity, and residual expression grouping matches C. Shuffling, 20 points, 2×5 runs, 20 inner launches, 10 full-sweep warmups, minimum definition and sample standard deviations are preserved.

Host initialization, strict argument validation, labelled output rows and explicit `--allow-host` remain documented translation choices. They do not add device synchronization or measured kernel work.

## Verification limits

GNU Fortran/GCC 14.2.0 compiled all builds. Checked and distribution runs cover all methods. Independent C/Fortran functional comparison checks 96 final arrays, atomic/reduction buckets, and exact delay samples. C is compiled by GCC with `__NVCOMPILER` selecting the source branch; this tests source semantics, not NVHPC GPU code generation. Local host fallback cannot verify actual GPU transfer directions, requested/actual thread-team counts, or offload performance. No claim of device-measurement equivalence is made.

## Unified layout and build update — 8 October 2026

The Fortran source files were moved unchanged into root `src/`, alongside their C counterparts. Tests now live in root `tests/`; `FORTRAN.md` and this audit are root documentation. The separate Fortran subdirectory/Makefile was removed. `src/common.f90` supplies module interfaces rather than a manually maintained C-style header, and is compiled before `src/microbenchmark.F90`.

One root Makefile retains C as the unspecified default, supports explicit `BENCH_LANG=c|fortran`, and auto-detects from compiler/profile choices. It keeps the existing executable names. Each selected target rebuilds, and per-language/per-mode generated directories prevent stale binaries and concurrent module-file conflicts. All existing C compiler profiles remain unchanged. NVFortran and GNU Fortran profiles are added with `-O0`; host GNU verification is separated from GPU profile flags.

The language-selection, parallel-build, compiler/flag-switch and relative-path tests passed with GNU C/Fortran. The complete earlier kernel/statistics verification was rerun after relocation. No benchmark timing region, mapping clause, team/thread clause, delay kernel or statistical estimator was edited in this update. NVHPC/GPU compilation remains unverified locally.
