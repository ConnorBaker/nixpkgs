# Nixpkgs instantiation memoization benchmarks

This file compares nixpkgs evaluation without memoization against the memoizing
entry point, and sweeps the radix of the reversible trie the memoizer uses as
its cache.

## Method

The benchmark command is:

```console
NIX_SHOW_STATS=1 nix eval --json -f nixos/release.nix closures > /dev/null
```

That workload evaluates four NixOS system closures (`smallContainer`,
`tinyContainer`, `ec2`, and `kde`), each of which instantiates nixpkgs
repeatedly through the module system, so it exercises the recursive
instantiations the memoizer targets.

The wall time is measured by the command runner. The evaluator columns are
emitted by Nix through `NIX_SHOW_STATS=1`. Each configuration is evaluated ten
times, each time in a fresh `nix eval` process. The ten rounds are interleaved:
every round runs each configuration once, in the same order, so drift over the
length of the sweep is spread across configurations instead of being
concentrated in one of them.

The configurations are the tree without memoization, and the memoizing tree
with `pkgs/top-level/memoize.nix` at radix 2, 4, 8, and 16. Radix 4 is the in-
tree file. The other radixes differ from it only in the number of digits per
byte, the divisors used to produce those digits, and the strict child keys of a
trie node; radix 16 additionally draws its digits from the hexadecimal alphabet
already defined in the file, so that every digit stays one character wide. All
five configurations evaluate the workload to byte-identical output (SHA-256
`087ba66b2423cd277b0609a1f7e43c174d06ca7ceda35def7629f2ac7c1c7b20`), so they
differ in how they evaluate, not in what they evaluate.

### Measuring interference

This machine runs other work, and an evaluation that loses the CPU to it looks
exactly like a slow implementation. Rather than infer contamination from the
spread of the wall times, each run records what the kernel observed while it
ran: processes created machine-wide (`/proc/stat`), CPU-seconds burned machine-
wide minus this evaluator's own `cpuTime` (the External CPU column, so it
counts only everyone else), CPU and memory stall time (`/proc/pressure`), and
major faults (`/proc/vmstat`). Each run is also preceded by a gate that waits
for the machine to go quiet, up to 60 seconds, requiring under 20 percent of
cores busy, under 100 forks per second, and at least 6 GiB of memory available.

The memory check counts the ZFS ARC above its `c_min` floor as available.
`MemAvailable` excludes the ARC, which on this host holds tens of gigabytes of
reclaimable cache, so gating on `MemAvailable` alone would stall on scarcity
that does not exist. Every run in the tables below passed the gate rather than
timing out.

Runs marked † have a modified z-score above 3.5 against the median wall time of
their own configuration. The interference columns are what decides whether such
a run is evidence about the implementation or about the machine.

Measurements were taken on a 13th Gen Intel Core i9-13900K with 32 logical
cores, running Nix 2.36.0pre20260706_cff1f11. Nix evaluates with several
threads here: a run's `cpuTime` is normally well above its wall time.

## No memoization

The baseline is the tree as it stood before this commit: `nixpkgsFun` in
`pkgs/top-level/default.nix` and the import in `pkgs/top-level/impure.nix`
instantiate `pkgs/top-level/default.nix` directly, so every recursive
instantiation builds a fresh package set.

| Run | Wall (s) | CPU (s) | GC (s) | GC cycles | Total allocated (bytes) | External CPU (s) | Forks | Major faults |
| ---: | -------: | ------: | -----: | --------: | ----------------------: | ---------------: | ----: | -----------: |
| 1 † | 33.266 | 38.757 | 1.190 | 15 | 10,653,725,376 | 113.2 | 1,577 | 4,523 |
| 2 | 27.570 | 36.190 | 1.069 | 15 | 10,653,710,544 | 35.9 | 125 | 366 |
| 3 | 28.293 | 38.093 | 1.157 | 15 | 10,653,712,240 | 99.6 | 2,218 | 1,623 |
| 4 | 28.579 | 41.736 | 1.378 | 14 | 10,653,712,688 | 83.2 | 131 | 2,179 |
| 5 | 29.568 | 45.304 | 1.608 | 17 | 10,653,704,352 | 88.9 | 309 | 17,603 |
| 6 | 29.622 | 42.192 | 1.382 | 14 | 10,653,712,384 | 59.8 | 427 | 1,358 |
| 7 | 29.535 | 40.412 | 1.314 | 16 | 10,653,691,744 | 42.0 | 194 | 94 |
| 8 | 29.062 | 41.876 | 1.396 | 17 | 10,653,709,280 | 11.6 | 184 | 942 |
| 9 | 29.305 | 43.025 | 1.482 | 14 | 10,653,708,192 | 9.7 | 144 | 72 |
| 10 | 28.732 | 36.710 | 1.055 | 15 | 10,653,701,360 | 40.6 | 752 | 436 |

Summary:

- Median wall time: 29.184 s
- Fastest wall time: 27.570 s
- Mean wall time: 29.353 s (standard deviation 1.522 s)
- Median evaluator CPU time: 41.074 s
- Median total allocated: 10,653,709,912 bytes
- Median external CPU during a run: 50.9 s
- Thunks: 123,129,012
- Function calls: 79,243,357
- Primitive operation calls: 38,250,860
- Attribute lookups: 50,443,377
- Values: 187,303,418
- Attribute sets: 28,945,492
- Avoided evaluations: 102,510,542
- Flagged runs: 1

## Memoized, radix 4

This is the in-tree implementation. It encodes each byte of the JSON key as
four base-4 digits. The trie path is therefore reversible, so its leaves can
reconstruct the input without using `builtins.toFile` or reading a store
object. Trie traversal and path reconstruction use evaluator builtins to avoid
consuming one Nix call frame per digit. The generic memoizer reports a path-
aware error for functions and other unsupported values; the nixpkgs
instantiation wrapper enables its explicit fallback mode because the release
workload supplies overlays containing functions.

| Run | Wall (s) | CPU (s) | GC (s) | GC cycles | Total allocated (bytes) | External CPU (s) | Forks | Major faults |
| ---: | -------: | ------: | -----: | --------: | ----------------------: | ---------------: | ----: | -----------: |
| 1 | 16.987 | 27.213 | 1.041 | 12 | 6,946,279,536 | 38.4 | 70 | 857 |
| 2 | 17.200 | 30.874 | 1.281 | 13 | 6,946,275,568 | 22.7 | 90 | 116 |
| 3 | 16.783 | 27.920 | 1.090 | 14 | 6,946,271,360 | 40.2 | 212 | 394 |
| 4 | 18.184 | 33.692 | 1.476 | 13 | 6,946,284,080 | 61.2 | 54 | 116 |
| 5 | 18.034 | 30.211 | 1.255 | 13 | 6,946,280,480 | 28.4 | 164 | 610 |
| 6 | 18.501 | 29.673 | 1.197 | 12 | 6,946,279,232 | 30.1 | 155 | 54 |
| 7 | 17.876 | 29.897 | 1.225 | 12 | 6,946,273,856 | 12.9 | 313 | 172 |
| 8 | 17.624 | 29.438 | 1.214 | 14 | 6,946,266,608 | 6.2 | 115 | 135 |
| 9 | 17.850 | 30.813 | 1.257 | 12 | 6,946,274,272 | 6.6 | 113 | 209 |
| 10 | 18.436 | 34.215 | 1.491 | 12 | 6,946,260,720 | 20.5 | 284 | 76 |

Summary:

- Median wall time: 17.863 s
- Fastest wall time: 16.783 s
- Mean wall time: 17.747 s (standard deviation 0.593 s)
- Median evaluator CPU time: 30.054 s
- Median total allocated: 6,946,274,920 bytes
- Median external CPU during a run: 25.6 s
- Thunks: 100,436,216
- Function calls: 71,778,886
- Primitive operation calls: 35,354,801
- Attribute lookups: 47,563,399
- Values: 142,043,404
- Attribute sets: 24,159,044
- Avoided evaluations: 86,530,994
- Flagged runs: none

### Compared with no memoization

- Median wall time: -38.8% (1.63x speedup)
- Fastest wall time: -39.1%
- Median evaluator CPU time: -26.8%
- Median total allocated: -34.8%
- Thunks: -18.4%
- Function calls: -9.4%
- Primitive operation calls: -7.6%
- Attribute lookups: -5.7%
- Values: -24.2%
- Attribute sets: -16.5%

## Radix sweep

Each radix uses the same reversible UTF-8 byte encoding, linked path, iterative
traversal, and unsupported-value fallback policy. Only the number of digits per
byte and the strict child keys at each trie node change.

### Radix 2

| Run | Wall (s) | CPU (s) | GC (s) | GC cycles | Total allocated (bytes) | External CPU (s) | Forks | Major faults |
| ---: | -------: | ------: | -----: | --------: | ----------------------: | ---------------: | ----: | -----------: |
| 1 | 18.192 | 33.926 | 1.555 | 13 | 7,078,347,168 | 49.6 | 368 | 1,931 |
| 2 | 17.574 | 30.851 | 1.372 | 13 | 7,078,333,872 | 23.8 | 95 | 153 |
| 3 | 17.373 | 29.715 | 1.304 | 14 | 7,078,360,832 | 44.0 | 142 | 3,212 |
| 4 | 17.746 | 33.279 | 1.541 | 13 | 7,078,336,416 | 60.5 | 73 | 10,833 |
| 5 | 18.502 | 30.296 | 1.343 | 14 | 7,078,355,776 | 55.0 | 149 | 5,844 |
| 6 | 19.394 | 32.280 | 1.456 | 12 | 7,078,357,312 | 56.2 | 464 | 827 |
| 7 | 17.901 | 29.020 | 1.265 | 14 | 7,078,352,512 | 25.6 | 113 | 5,532 |
| 8 | 18.078 | 29.576 | 1.270 | 13 | 7,078,348,368 | 7.4 | 104 | 241 |
| 9 | 18.393 | 30.799 | 1.346 | 12 | 7,078,356,688 | 7.5 | 116 | 43 |
| 10 | 18.324 | 31.811 | 1.424 | 13 | 7,078,353,440 | 35.4 | 269 | 97 |

Summary:

- Median wall time: 18.135 s
- Fastest wall time: 17.373 s
- Mean wall time: 18.148 s (standard deviation 0.570 s)
- Median evaluator CPU time: 30.825 s
- Median total allocated: 7,078,352,976 bytes
- Median external CPU during a run: 39.7 s
- Thunks: 101,229,240
- Function calls: 74,365,012
- Primitive operation calls: 36,429,035
- Attribute lookups: 50,239,741
- Values: 145,160,944
- Attribute sets: 24,419,810
- Avoided evaluations: 89,387,850
- Flagged runs: none

### Radix 8

| Run | Wall (s) | CPU (s) | GC (s) | GC cycles | Total allocated (bytes) | External CPU (s) | Forks | Major faults |
| ---: | -------: | ------: | -----: | --------: | ----------------------: | ---------------: | ----: | -----------: |
| 1 † | 16.870 | 28.101 | 1.118 | 13 | 6,918,918,176 | 38.5 | 78 | 90 |
| 2 | 18.145 | 28.583 | 1.108 | 13 | 6,918,911,520 | 75.9 | 4,939 | 26,937 |
| 3 | 18.043 | 30.810 | 1.311 | 14 | 6,918,904,576 | 53.5 | 189 | 1,434 |
| 4 | 17.913 | 28.092 | 1.116 | 13 | 6,918,917,072 | 60.9 | 130 | 50,971 |
| 5 | 18.282 | 31.385 | 1.279 | 13 | 6,918,907,104 | 27.9 | 141 | 1,137 |
| 6 | 17.797 | 28.329 | 1.133 | 14 | 6,918,924,288 | 29.5 | 180 | 251 |
| 7 | 17.885 | 29.787 | 1.212 | 12 | 6,918,927,344 | 13.1 | 429 | 6,413 |
| 8 | 17.859 | 30.496 | 1.244 | 12 | 6,918,931,904 | 6.4 | 117 | 97 |
| 9 | 17.983 | 31.616 | 1.347 | 13 | 6,918,901,296 | 9.5 | 131 | 274 |
| 10 | 17.500 | 27.885 | 1.119 | 13 | 6,918,917,168 | 17.9 | 321 | 86 |

Summary:

- Median wall time: 17.899 s
- Fastest wall time: 16.870 s
- Mean wall time: 17.828 s (standard deviation 0.396 s)
- Median evaluator CPU time: 29.185 s
- Median total allocated: 6,918,917,120 bytes
- Median external CPU during a run: 28.7 s
- Thunks: 100,411,797
- Function calls: 71,132,353
- Primitive operation calls: 35,086,242
- Attribute lookups: 46,894,312
- Values: 141,437,856
- Attribute sets: 24,093,851
- Avoided evaluations: 85,816,778
- Flagged runs: 1

### Radix 16

| Run | Wall (s) | CPU (s) | GC (s) | GC cycles | Total allocated (bytes) | External CPU (s) | Forks | Major faults |
| ---: | -------: | ------: | -----: | --------: | ----------------------: | ---------------: | ----: | -----------: |
| 1 | 18.263 | 31.546 | 1.332 | 12 | 6,891,543,472 | 38.4 | 297 | 59,192 |
| 2 | 17.900 | 33.124 | 1.460 | 13 | 6,891,528,976 | 81.2 | 4,373 | 8,347 |
| 3 | 17.075 | 30.266 | 1.286 | 13 | 6,891,547,344 | 39.6 | 106 | 1,198 |
| 4 | 17.945 | 30.557 | 1.268 | 12 | 6,891,550,512 | 44.9 | 118 | 8,498 |
| 5 | 18.438 | 32.216 | 1.363 | 12 | 6,891,536,416 | 44.9 | 399 | 549 |
| 6 | 17.842 | 30.790 | 1.292 | 13 | 6,891,524,512 | 26.8 | 140 | 153 |
| 7 | 17.607 | 28.969 | 1.212 | 13 | 6,891,537,136 | 8.0 | 131 | 1,103 |
| 8 | 17.709 | 31.635 | 1.365 | 13 | 6,891,527,248 | 6.6 | 100 | 63 |
| 9 | 17.592 | 28.782 | 1.175 | 13 | 6,891,534,272 | 12.1 | 225 | 142 |
| 10 | 17.329 | 28.658 | 1.189 | 14 | 6,891,531,072 | 23.9 | 382 | 89 |

Summary:

- Median wall time: 17.776 s
- Fastest wall time: 17.075 s
- Mean wall time: 17.770 s (standard deviation 0.406 s)
- Median evaluator CPU time: 30.673 s
- Median total allocated: 6,891,535,344 bytes
- Median external CPU during a run: 32.6 s
- Thunks: 100,387,391
- Function calls: 70,485,823
- Primitive operation calls: 34,817,684
- Attribute lookups: 46,225,228
- Values: 140,832,321
- Attribute sets: 24,028,661
- Avoided evaluations: 85,103,411
- Flagged runs: none

### Flagged runs

- No memoization, run 1: 33.266 s, 14.0% slower than its median, 113.2 external CPU-seconds, 4,523 major faults
- Radix 8, run 1: 16.870 s, 5.7% faster than its median, 38.5 external CPU-seconds, 90 major faults

The interference columns separate these two cases, which the wall times alone
would not. No memoization run 1 saw 113.2 external CPU-seconds, the largest of
any run in the sweep against a median of 35.6 s across all fifty runs,
alongside 4,523 major faults as the sweep's first evaluation faulted its
working set in: that is the machine, not the baseline. Radix 8 run 1 has no
such signature — 38.5 external CPU-seconds is unremarkable here, and it was
flagged for being fast, not slow. It is flagged because radix 8's other runs
cluster so tightly that its median absolute deviation is the smallest in the
sweep (0.123 s against 0.447 s for the widest), which makes the z-score
sensitive to an ordinary fast run.

Wall time also does not track the measured external load. Averaged over rounds
1 to 3 the machine imposed 53.0 external CPU-seconds per run, against 14.8 over
rounds 8 to 10, yet the configurations did not get uniformly faster as the
machine quieted: over those same windows the baseline moved -2.3% while radix 4
moved +5.8%. Below the level of interference that the flagged baseline run
shows, there is a noise floor this instrumentation does not explain, and it is
the same size as the differences between radixes.

### Comparison

| Configuration | Digits per byte | Children per node | Median wall (s) | Fastest wall (s) | Wall sd (s) | Median CPU (s) | Median allocated (bytes) | Thunks | Values | Attribute sets | Lookups |
| ------------- | --------------: | ----------------: | --------------: | ---------------: | ----------: | -------------: | -----------------------: | -----: | -----: | -------------: | ------: |
| No memoization | — | — | 29.184 | 27.570 | 1.522 | 41.074 | 10,653,709,912 | 123,129,012 | 187,303,418 | 28,945,492 | 50,443,377 |
| Radix 2 | 8 | 2 | 18.135 | 17.373 | 0.570 | 30.825 | 7,078,352,976 | 101,229,240 | 145,160,944 | 24,419,810 | 50,239,741 |
| Radix 4 | 4 | 4 | 17.863 | 16.783 | 0.593 | 30.054 | 6,946,274,920 | 100,436,216 | 142,043,404 | 24,159,044 | 47,563,399 |
| Radix 8 | 3 | 8 | 17.899 | 16.870 | 0.396 | 29.185 | 6,918,917,120 | 100,411,797 | 141,437,856 | 24,093,851 | 46,894,312 |
| Radix 16 | 2 | 16 | 17.776 | 17.075 | 0.406 | 30.673 | 6,891,535,344 | 100,387,391 | 140,832,321 | 24,028,661 | 46,225,228 |

Relative to no memoization:

| Configuration | Median wall | Speedup | Median CPU | Median allocated | Thunks | Values |
| ------------- | ----------: | ------: | ---------: | ---------------: | -----: | -----: |
| Radix 2 | -37.9% | 1.61x | -25.0% | -33.6% | -17.8% | -22.5% |
| Radix 4 | -38.8% | 1.63x | -26.8% | -34.8% | -18.4% | -24.2% |
| Radix 8 | -38.7% | 1.63x | -28.9% | -35.1% | -18.4% | -24.5% |
| Radix 16 | -39.1% | 1.64x | -25.3% | -35.3% | -18.5% | -24.8% |

### Reading the sweep

Every radix recovers essentially the same win over no memoization: the median
wall time falls by 38 to 39 percent, and allocation by about 35 percent. The
choice of radix is a second-order effect on top of that.

The evaluator counters are deterministic and reproducible. Each configuration
reported identical thunk, value, attribute-set, lookup, function-call,
primitive-call, and avoided-evaluation counts in all ten of its runs; its total
allocation varied by at most 33,632 bytes across runs; and every one of those
counts is bit-identical to the counts from an earlier, separately run sweep.
They fall monotonically as the radix rises, because a higher radix means fewer
digits, and therefore fewer trie nodes, per byte of key: radix 16 allocates
0.8% less than radix 4, and radix 2 is the largest of the four on every one of
those counters.

Wall and CPU time do not resolve that ordering. The median wall times of radix
4, 8, and 16 span 0.123 s, well inside the run-to-run standard deviation of a
single configuration (0.593 s for the widest of the three). The sharpest
evidence is that the nominal winner is not stable: an earlier sweep of ten
rounds on the same machine, using the same interleaved design but without the
quiet gate or the interference columns, made radix 4 the fastest by median,
while this one makes radix 16 fastest, at 17.069 s and 17.776 s respectively.
Ten rounds separate memoized from unmemoized evaluation, a gap of about 11
seconds, but they do not rank radix 4, 8, and 16 against each other, and
neither sweep identifies a fastest radix among the three.

Radix 2 is the one member of the sweep that is consistently worst: it has the
highest median wall time here (+1.5% against radix 4), it was also the highest
in the earlier sweep, and it is the largest of the four on every deterministic
counter. Eight digits per byte makes the deepest trie in the sweep, and that
extra path length shows up in both the counters and the clock.

Radix 4 is what the tree uses. This data establishes that memoizing is a large
win at any radix in the sweep, and that radix 4 is among the fastest measured;
it does not establish radix 4 as an optimum over radix 8 or 16. The
deterministic counters, which mildly favor a higher radix, are the only part of
this data fine-grained enough to rank those three.

### A note on what the instrumentation caught

An earlier run of this benchmark, without the quiet gate and the interference
columns, produced a round in which every configuration took between 1.3 and 2.5
times its own median. The kernel's record identified the cause as load from
elsewhere on the machine: over that round the fork rate rose from single digits
to several hundred processes per second, and Nix's `cpuTime`-to-wall ratio
collapsed from between 1.71 and 1.75 to between 0.92 and 1.09, meaning the
evaluator was waiting for cores rather than working: less than one core of
progress on a 32-core machine. Wall-time outliers alone could not have told
that apart from a slow implementation, which is why each run now carries its
own contention measurements.
