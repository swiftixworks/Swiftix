# SwiftixDemo

`SwiftixDemo` is a standalone macOS Swift package that demonstrates how an external application consumes Swiftix's public API. The package uses a local dependency on `../` for the `Swiftix` and `SwiftixGo` products provided by the repository root.

This example focuses on the core and toolchain APIs and does not bundle a distribution rootfs. `SwiftixDistribution` builds the complete set of preinstalled commands, default `/etc` configuration, and package sources into a `.sximg` that a consumer can restore on a VM's first boot.

Run it from the repository root:

```bash
swift run --package-path Example SwiftixDemo
```

Build it without running:

```bash
swift build --package-path Example -Xswiftc -warnings-as-errors
```

On macOS, open `Example/Package.swift` in Xcode when an IDE project is preferred.
