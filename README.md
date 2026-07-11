# Volumetric

<p align="center">
    <img src="https://img.shields.io/badge/Swift-orange.svg" alt="Swift" />
    <a href="https://swift.org/package-manager">
        <img src="https://img.shields.io/badge/swiftpm-compatible-brightgreen.svg?style=flat" alt="Swift Package Manager" />
    </a>
</p>

Volumetric is an open-source package of volumetric data structures and algorithms for the Swift programming language.

## Contents
The package provides the following data structures and algorithms:

- **Bounds**: An N-dimensional axis-aligned bounding volume that encloses a region of space and answers the containment, intersection, and ray tests the acceleration structures are built on.
- **BVH**: A spatial acceleration structure that organizes elements into a hierarchy of nested bounding volumes, with multiple builders balancing construction time against query performance.
- **Grid**: A spatial acceleration structure that bins positioned elements into a uniform lattice of cells, tuned by a single cell size.

### Bounds

`Bounds` is an axis-aligned bounding volume defined by a minimum and maximum extreme, generic over dimension.

Specialize it with a two-component vector and it describes a rectangle; three components, a box; more, a hyper-box — one implementation across every dimension, working over both the fast SIMD-backed vectors and slower vectors of arbitrary dimension.

It is the geometric primitive the acceleration structures are built on: it combines and clips regions (`union`, `intersection`), tests points for containment, reports the `surfaceArea` and `center` that builders use to score splits, and answers ray/box intersection by returning the entry–exit interval along the ray.

Most operations require component-wise arithmetic (`VectorMath`) and are exposed conditionally, so a bounds stays usable, if limited, over any vector type. The sorted-extremes invariant (`min` ≤ `max` component-wise) is maintained internally and cannot be broken from outside the module.

```swift
let a = Bounds(min: Vector3(0, 0, 0), max: Vector3(1, 1, 1))
let b = Bounds(min: Vector3(2, 2, 2), max: Vector3(3, 3, 3))
let combined = a.union(with: b)           // encloses both
let hit = a.intersects(ray: someRay)      // entry/exit interval, or nil
```

### BVH

The `BVH` (bounding volume hierarchy) organizes elements that have spatial *extent* into a tree of nested bounding volumes, so a query can prune whole subtrees instead of testing every element.

It is an immutable value type: build it once from any sequence of `Boundable` elements using a `BVHBuilder`, and it is then read-only and freely queryable.

Internally the tree is flattened depth-first with a per-node *escape index*, which makes traversal stackless and GPU-friendly, and it can be *refitted* in `O(n)` against rigidly moved geometry, the cheap alternative to a full rebuild when connectivity is stable, as in animation.

The query surface is dimension-agnostic: nearest element (`closest`), k-nearest (`nearest`), everything within a radius or a bounding box, ray traversal and nearest-hit intersection, plus `Collection`/`Sequence`.

Only the topology and leaf ordering are the builder's responsibility; the memory layout, bounds propagation, escape links, and traversal are shared, so a hierarchy built by one strategy is the same type as one built by another and the two are interchangeable.

```swift
let bvh = BVH(elements, using: .binnedSAH)
let nearest = bvh.closest(to: point)          // nearest element
let neighbours = bvh.nearest(10, to: point)   // ten nearest
let inRange = bvh.elements(within: 5, of: point)
```

Four builders trade construction time against query performance:

#### MedianSplit

A top-down builder that splits primitives at the median of their centroids, along the axis in which they are most spread out. This yields a balanced tree in `O(n log² n)` but makes no attempt to minimise surface area, so it is the cheapest, quality-blind build — a useful baseline and reference. Tuned by `maximumLeafSize`.

#### BinnedSAH

A top-down builder using a binned surface area heuristic. At each node the centroids are sorted into a fixed number of bins per axis, candidate split planes are swept, and the primitives are partitioned at the cheapest plane found. Binning makes the split search `O(n)` per node (so the whole build is `O(n log n)`) while producing a hierarchy far cheaper to traverse than `MedianSplit`.

**This is the recommended general-purpose builder.** Tuned by `maximumLeafSize` and `binCount` (12–16 is the usual sweet spot).

#### LinearBVH

A builder that orders primitives along a Morton (Z-order) curve and builds a radix tree over the sorted codes. The space-filling curve is its only notion of locality (no split is ever scored against a cost function) so the build is extremely fast (a sort plus a linear pass) but the hierarchy is of lower quality.

Reach for it when the tree is rebuilt frequently, or destined for the GPU, and build time dominates. Tuned by `maximumLeafSize`.

#### AAC

Approximate agglomerative clustering (Gu et al. 2013) builds the hierarchy *bottom-up*: primitives are Morton-sorted, then the closest clusters (t)hose whose combined bounds have the smallest surface area) are greedily merged up the tree, down to a target count that shrinks with height.

It drives the tree toward tight, single-primitive leaves, giving the fewest ray/primitive tests of any builder here, at the cost of a more involved build and roughly twice the node count; the two independent halves of each split are clustered in parallel across cores.

Two presets bracket the quality/speed trade-off — `.aacHighQuality` (δ=20, ε=0.1) and `.aacFast` (δ=4, ε=0.2) — or use `.aac(...)` to tune `delta`, `epsilon`, `maximumLeafSize`, and `parallel`.

**Builder comparison** — 10,000 primitives, 4,000 rays (Release build, best-of-runs):

| Builder | Build (ms) | SAH (rel.) | Tests / ray | Nodes |
|---|---:|---:|---:|---:|
| LinearBVH | 3.4 | 0.97× | 9.8 | 7,107 |
| MedianSplit | 6.2 | 1.00× | 9.4 | 7,711 |
| BinnedSAH | 26.6 | 0.89× | 8.3 | 6,599 |
| AAC-Fast | 11.0 | 0.92× | 4.4 | 12,667 |
| AAC-HQ | 19.3 | 0.98× | 3.7 | 12,883 |

*SAH is the surface-area-heuristic cost relative to `MedianSplit` (lower is cheaper to traverse in theory, counting node visits). Tests/ray is the measured mean number of ray/primitive intersection tests (lower is faster in practice). AAC minimises primitive tests by building tighter leaves, but visits more nodes to do it. Absolute times are from a single machine and will vary — the ordering is the point.*

### Grid

`Grid` organizes *positional* elements into a uniform lattice of cells: the natural structure for point clouds, particle systems, and fixed-radius neighbour search. Each element is binned into exactly one cell by its position.

Like the BVH it is an immutable value type, built once from any sequence of `Positionable` elements, but a rebuild is only a sort plus a linear pass, cheap enough to do every frame for fully dynamic data.

Storage is the compact, GPU-style form: elements are laid out in Morton (Z-order) cell order so spatially-near cells are near in memory, with a sorted occupied-cell directory mapping each cell to its span of elements. Empty cells cost nothing, so the grid stays sparse and bounded in any dimension.

Queries walk the lattice through stack scratch buffers with no per-query allocation, and cover the same surface as the BVH: `closest`, k-nearest, radius, bounding-box, and ray.

```swift
let grid = Grid(particles, cellSize: 4)
let neighbours = grid.nearest(10, to: point)
let inRange = grid.elements(within: 4, of: point)
```

**Grid vs. BVH** — uniform points, 2,000 queries, k=10 (the BVH is built over point-bounding boxes with `BinnedSAH`; Release build, best-of-runs, milliseconds):

| Points | Structure | Build | closest | kNN | radius | ray |
|---|---|---:|---:|---:|---:|---:|
| 1,000 | **Grid** | 0.10 | 2.71 | 12.80 | 0.50 | 0.98 |
| | BVH | 2.40 | 1.47 | 14.19 | 0.32 | 0.75 |
| 10,000 | **Grid** | 1.00 | 4.13 | 17.93 | 2.07 | 2.66 |
| | BVH | 25.57 | 5.88 | 44.27 | 0.99 | 1.76 |
| 100,000 | **Grid** | 12.42 | 4.91 | 20.95 | 9.28 | 6.63 |
| | BVH | 282.40 | 19.79 | 121.68 | 3.51 | 3.20 |

*The grid builds ~20–25× faster and pulls ahead on `closest`/`kNN` as the point count grows, while the BVH's tighter pruning keeps it ahead on `radius` and `ray` queries. Rule of thumb: reach for the **Grid** for dynamic point data and neighbour search, and the **BVH** for extent-bearing geometry or ray-heavy workloads.*

## Documentation

For more information on usage, the Volumetric documentation can be found at: https://mattcox.github.io/Volumetric/.

## Installation

Volumetric is distributed using the [Swift Package Manager](https://swift.org/package-manager). To install it within another Swift package, add it as a dependency within your `Package.swift` manifest:

```swift
let package = Package(
    // . . .
    dependencies: [
        .package(url: "https://github.com/mattcox/Volumetric.git", branch: "main")
    ],
    // . . .
)
```

If you’d like to use Volumetric within an iOS, macOS, watchOS or tvOS app, then use Xcode’s `File > Add Packages...` menu command to add it to your project.

Import Volumetric wherever you’d like to use it:
```swift
import Volumetric
```

Alternatively, you can import any of the individual data structures or algorithms directly — `VolumetricCore` (for `Bounds`), `VolumetricBVH`, or `VolumetricGrid`. For example, if you simply want the BVH:
```swift
import VolumetricBVH
```
