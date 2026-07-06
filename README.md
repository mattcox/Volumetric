# 🧊 Volumetric
Volumetric is an open-source package of volumetric data structures and algorithms for the Swift programming language.

## Contents
The package provides the following data structures and algorithms:

- **BVH**, a bounding volume hierarchy that provides efficient traversal of N-dimensional space.

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

Alternatively, you can import any of the individual data structures of algorithms. For example if you simply want the BVH, you can import it directly.
```swift
import BVH
```
