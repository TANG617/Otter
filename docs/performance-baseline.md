# Performance Baseline

No performance result is recorded before the exact implemented app and focused flow are captured. Simulator figures are diagnostic only; final budgets require a physical iPhone/iPad.

| Flow | Build | Simulator/device | Dataset/cache | Measured result | Status |
|---|---|---|---|---|---|
| A: cold fixture launch to usable timeline | — | — | 10k / cold | — | Not measured |
| B: aggressive timeline scroll | — | — | 10k / mixed | — | Not measured |
| C: viewer paging, zoom, close | — | — | fixture / warm neighbors | — | Not measured |

Required evidence includes main-thread decode count, duplicate byte transfers, decode concurrency, cancellation, blank-frame observations, memory envelope, and memgraph ownership analysis. Trace and memgraph artifacts remain gitignored.

