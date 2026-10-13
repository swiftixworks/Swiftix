# Swiftix Performance and Long-Running Behavior

> Last verified: 2026-08-13<br>
> Scope: the core, network stack, VFS, and Swiftix Go runtime

## Assessment

Measured against teaching, protocol experiments, and small-to-medium network simulations, current performance is approximately **7/10**. The `EventLoop`, shallow VFS operations, and basic IPv4 data path do not require architectural rewrites. The principal limits are the single executor, packet copying, algorithmic complexity in the Go VM, and Release compilation cost.

The single serial executor is an explicit tradeoff for determinism and a simple state model, not a lock-contention bug to eliminate. A long-running callback or guest can still cause head-of-line blocking. When multiple cores are required, downstream consumers should shard independent VMs or simulation domains rather than share mutable core state.

## Stability Foundations Already in Place

- Timers use a heap and support physical cancellation through event tokens.
- Pipes, PTYs, UDP inboxes, ARP pending queues, TCP receive buffers, and packet history all have explicit capacities.
- Packet history uses a fixed-capacity ring.
- The Go VM has an instruction quantum and resource limits.
- Shutdown cancels owner-scoped work, with tests covering the relevant invariants.
- Parsers, images, and package paths limit size, count, and truncated input.

Earlier findings that multiple queues were unbounded and that stale TCP timers could only be invalidated logically are obsolete and are no longer current risks.

## Current Baseline

Apple M4 Release microbenchmarks from 2026-08-06:

| Scenario | Result |
| --- | ---: |
| Insert / fire and drain 100k timers | About 4.2 ms / 25.4 ms |
| Create 20k VFS files | About 33.5 ms |
| Perform 100k shallow-path `stat` calls | About 93 ms |
| Loop back 20k × 512 B UDP packets | About 115–118 MiB/s |
| Run a normal 100k-iteration Go VM loop | About 0.17 s |
| Insert or query 20k Go map keys | About 1.1 s each (linear map storage; see the 2026-10-13 note below) |
| Clean all-product Release build | About 202 s, peak RSS about 2.34 GB |

Release assessment from 2026-08-13:

- 808 tests across 121 suites;
- approximately 83.7% line coverage and 72.9% region coverage;
- approximately 214 seconds for an all-product Release build with Swift 6.3.3 on macOS.

Path-search permission check, measured 2026-10-07 (Release, `stat` of a file
at directory depth 4, 32, and 256): about 0.4 µs per path component as uid 0,
which carries no search policy, and about 0.5 µs as a non-root user (13–19%
more). Cost stays linear in depth; a refused walk stops at the refusing
directory. Directory depth is not limited and does not consume host stack:
`VNode` teardown, VFS accounting, snapshot capture and restore, and the
tree-walking commands keep explicit worklists, and tests cover chains 5,000
levels deep on a 512 KiB secondary-thread stack. Path-based walks of such a
tree are quadratic in depth, because every syscall re-resolves its path. A
snapshot's legacy `root` projection stops at 256 levels; the inode table
carries the rest.

Go map storage, measured 2026-10-13 (Debug build, one program that inserts
and then reads back N integer keys): 5,000 keys took about 5.5 s and 20,000
keys about 89 s with the linear storage, which also copied and re-measured the
whole map on every insert, and about 0.24 s and 0.88 s with the hash-indexed
storage that updates the map in place. Cost is now linear in N; the remaining
time is the VM's per-instruction cost. The Release row above predates the
change and has not been re-measured.

These numbers establish an order of magnitude only. The microbenchmarks are not yet fixed in CI, and there is no real-device, complex-loss, or long-running soak dataset, so they do not form a cross-machine SLA.

## Unresolved Risks

| Priority | Risk | Impact |
| --- | --- | --- |
| P1 | Ethernet/IPv4/TCP/checksum paths repeatedly create or concatenate `[UInt8]` values | More allocation and copying for large packets or high packet rates |
| P1 | Some runtime collections remain linear structures (maps no longer are) | Larger goroutine and channel workloads degrade |
| P1 | A `[]byte` holds one tagged value per byte, and a slice store through a pointer path rebuilds its array | Byte-heavy programs pay about 32 accounted bytes per byte; `copy`, `ReadAt`, and `Read` into a whole backing array are the bulk paths |
| P1 | No soak test lasting at least one hour | Long-term stability of RSS, timers, and object counts is unproven |
| P2 | Deep-path resolution and full VFS snapshots scale with data size | Higher latency for deep trees and frequent snapshots |
| P2 | Synchronous observation hooks or long callbacks block the executor | Higher tail latency and cross-node interference |
| P2 | The large Go runtime raises Release optimization time | Slower CI and release feedback |

## 1.0 Performance Gate

Swiftix 1.0 has no line-rate throughput target, but it must demonstrate bounded long-running behavior:

- Run a mixed workload of TCP/UDP, loss and retransmission, stalled consumers, PTYs, processes, and the Go VM for at least one hour.
- Record RSS, timer count, process/file-descriptor counts, queue depths and high-water marks, and drop counts.
- After warmup, no metric may show unexplained, continuously monotonic growth.
- After node shutdown, owner work, timers, connections, and processes must return to their expected baselines.
- Preserve raw results with the fixed hardware and Swift toolchain; disclose material regressions in release notes.

Recommended regression scenarios:

| Category | Scale dimension | Metrics |
| --- | --- | --- |
| EventLoop | 10k/100k/1M timers at different cancellation ratios | Time, heap size, and peak memory |
| UDP/TCP | Packet size, concurrent flows, and 0–1% loss | Packets/s, throughput, retransmission, and copying |
| VFS | Depth, file count, and snapshot frequency | Operations/s, latency, and memory |
| Go VM | Map, goroutine, and channel counts | Instruction rate, GC, and longest occupancy |
| Soak | One-hour mixed workload | RSS and every resource high-water mark |

## Optimization Order

1. Establish the soak test and a repeatable baseline.
2. Replace important runtime queues with suitable data structures (Go maps are done).
3. Reduce network data-path copying.
4. Use compiler timing reports to split Go runtime optimization hotspots.
5. Add buffer pooling, scatter/gather, or parallel simulation domains only for demonstrated demand.

See [Build and Verification](../README.md#build-and-verification) for functional checks and the [product roadmap](roadmap.md) for complete exit criteria.
