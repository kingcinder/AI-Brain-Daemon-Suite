# Multi-Language Performance Optimization

Stage 1c of the Serpent Circle audits performance across **every** language in
the repo. This reference gives each language's canonical profilers and
techniques. Apply it after `improve-codebase-architecture` (1a) and
`python-performance-optimization` (1b, see that skill for Python depth).

## Universal rules (apply first, in every language)

1. **Measure before optimizing.** Profile the real workload; never guess.
2. **Complexity first, constants second.** Fix algorithmic (O(n²) → O(n log n))
   issues before micro-tuning.
3. **Avoid allocations in hot loops** (reuse buffers; watch boxing, string
   concatenation, closure allocation).
4. **Batch I/O** and keep I/O off the hot path (async, buffering, batching).
5. **Cache** repeated work; invalidate correctly.
6. **Prefer libraries that are native to the ecosystem** over reimplemented
   loops.

---

## Python
See the `python-performance-optimization` skill: cProfile, py-spy,
memory_profiler/tracemalloc, vectorization (NumPy), avoiding interpreter
overhead in tight loops (move to C/runtime), async for I/O-bound work.

## JavaScript / TypeScript
- **Profile:** Chrome DevTools CPU/Heap profilers; Node.js `--cpu-prof`,
  `--heap-prof`, `--prof-process`; `0x` flamegraphs.
- **Techniques:** avoid O(n²) with `Array#includes` in loops → `Set`/`Map`;
  reuse objects instead of per-iteration allocation; prefer typed arrays and
  `Uint8Array` for buffers; keep hot loops allocation-free; use
  `--turbo-fast-path-calls`-friendly patterns; avoid `JSON.parse/stringify` in
  tight paths; consider Worker threads only for CPU-bound parallel work.

## C#
- **Profile:** `dotnet-trace`, `dotnet-counters`, `dotnet-gcdump`, Visual
  Studio/VS Code performance profiler.
- **Techniques:** prefer `Span<T>`/`Memory<T>` over LINQ-heavy hot paths;
  avoid boxing (structs vs `object`); use `ArrayPool<T>` for buffer churn;
  `ReadOnlySpan` parsing; `async`/`await` for I/O, not CPU; consider source
  generators for reflection-heavy paths; AOT/trimming for startup+size.

## Rust
- **Profile:** `cargo flamegraph`/`perf`, `cargo bench` (criterion),
  `tokio-console` for async.
- **Techniques:** prefer `Vec` over `LinkedList`; avoid `clone()` in hot
  paths (borrow instead); use `#[inline]` judiciously; iterator chains over
  index loops (they optimize well); consider `RAYON` for parallel iteration;
  minimize `HashMap` hashing cost (`hashbrown`); measure with `--release`.

## PowerShell
- **Profile:** `Measure-Command`, `Measure-Object`, `Set-PSDebug -Trace` for
  hotspots.
- **Techniques:** avoid the pipeline in tight loops (it's slow) — use
  `foreach` statements and direct `.NET` method calls; build strings with
  `StringBuilder`; avoid repeated `Get-Content` — read once; use
  `-Filter`/`-LiteralPath` over broad wildcards; prefer `System.IO.File` for
  bulk I/O; silence/redirect streams you don't consume.

## Shell / Bash
The AI Brain Suite is predominantly bash — this one matters.
- **Profile:** `time`, `date +%s%N`, `set -x` traces; `bash -x` per script.
- **Techniques:** avoid external binaries in hot loops (`grep`/`sed`/`awk`
  per line → do it once, or use bash built-ins); prefer `[[ ]]` over `[ ]`
  (no fork); avoid subshells/`$( )`/pipelines in tight loops (each forks);
  use `readarray`/`mapfile` instead of `while read` subshells; batch
  operations (one `find` + `xargs` vs many `for` loops); use built-in
  arithmetic over `expr`/`awk` for math; beware `cat file | cmd` → `< file
  cmd`; `set -euo pipefail` early for correctness (fast-fail beats wasted
  work).

## Other languages (Go, Java, C/C++, Ruby, PHP, Swift, Kotlin, …)
Map to the universal rules plus the ecosystem's canonical profiler:
- **Go:** `pprof`, `go test -bench`, `go vet`.
- **Java:** JFR/JMC, async-profiler, avoid allocation in hot loops (escape
  analysis), prefer primitive streams/collections.
- **C/C++:** `perf`, gprof, valgrind/callgrind, avoid heap in hot paths,
  compiler flags (`-O2/-O3`, LTO).
- **Ruby:** `ruby-prof`, `stackprof`; **PHP:** Xdebug profiler, OPcache;
  **Swift/Kotlin:** instruments/`perf` equivalents.

## Output

For each language audited, record in the Stage 1 synthesis:
`<language> — profiler used, top N findings, fixes applied or planned`.
The synthesis (1d) merges these into the design doc.
