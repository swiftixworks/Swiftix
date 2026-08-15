# Swiftix Package Management Contract

> Last verified: 2026-08-15<br>
> Scope: `SwiftixPackages` and `pkg`

SwiftixPackages provides the Swiftix-native `.pkg` format and `pkg` interface over the public VFS, networking, and syscall APIs. Control stanzas and version ordering borrow proven Debian conventions while the archive, repository, and command contracts remain native to Swiftix.

## Layout and Sources

| Path | Purpose |
| --- | --- |
| `/etc/pkg/sources.list` | Package sources |
| `/var/lib/pkg/status` | Installed version, state, and file ownership |
| `/var/lib/pkg/lists/` | Fetched indexes |
| `/var/cache/pkg/archives/` | Downloaded `.pkg` files |
| `/var/lib/pkg/updates/` | Transaction staging |

The distribution provides the initial `sources.list`; an existing VM snapshot always takes precedence. Sources use Swiftix's flat repository format:

```text
repo http://packages.example/main ./
repo file:///srv/repo ./
```

The repository root contains `Packages` and `pool/*.pkg`. Supported source schemes are `http://`, which follows at most three standard redirects, and `file:///`, which reads the guest VFS.

`Packages` uses Debian control stanzas. `Size` and a 64-character hexadecimal `SHA256` are required:

```text
Package: hello
Version: 1:1.2.0-2
Architecture: svm64
Description: friendly greeter
Depends: libgreet (>= 1.0)
Filename: pool/hello_1.2.0-2.pkg
Size: 4096
SHA256: 6f1c...
```

When multiple sources provide the same version, the earlier source in `sources.list` wins.

## Metadata and `.pkg` v2

- Package names contain 2–128 lowercase ASCII characters and may include digits, `+`, `.`, and `-`.
- Versions use `[epoch:]upstream[-revision]` and follow dpkg's numeric/non-numeric and `~` ordering rules.
- Relations support `<<`, `<=`, `=`, `>=`, and `>>`.
- `Depends`, `Conflicts`, and unversioned `Provides` are supported.
- Architectures are `svm64` and `all`.

`.pkg` v2 is a deterministic container: control header, entry table, `%%`, and raw payload concatenated in entry order. Each file records its mode, length, and SHA-256; directories are explicit entries. Format v1 is no longer readable.

```text
!<swiftix-pkg>2
Package: hello
Version: 1.2.0-2
Architecture: svm64
Entry: file 0755 14 <sha256> /usr/bin/hello
Payload: 14
%%
<payload>
```

Installation is declarative: `pkg` applies archive entries and metadata but never executes package-provided code during install, upgrade, or removal.

Limits: 32 MiB per archive, 16 MiB per file, 4,096 entries, 4 MiB per index, and 8 MiB for the installed database.

Before installation, Swiftix validates the archive size and digest, every file digest, manifest/index consistency, architecture, canonical paths, forbidden prefixes, and existing ownership. Packages cannot write to `/proc`, `/dev`, `/sys`, or package-manager state paths themselves.

## Command Contract

```text
pkg update
pkg install|reinstall|remove|purge PACKAGE...
pkg autoremove
pkg upgrade|full-upgrade
pkg list [--installed|--upgradable]
pkg search TERM
pkg info PACKAGE...
pkg files PACKAGE...
pkg owner PATH
pkg arch
pkg clean
```

`pkg install ./file.pkg` resolves dependencies through configured repositories. Add `--no-deps` for an isolated local install. Common options include `-y`, `--simulate`, `--quiet`, `--no-deps`, `--reinstall`, `--force-overwrite`, and `--force-depends`. Usage errors exit with 2 and other failures with 1.

## Resolution and Transactions

The solver follows a deterministic minimal-change strategy:

- Choose the highest version satisfying all constraints, breaking equal-version ties by source order.
- Do not upgrade already satisfied dependencies automatically; explicitly requested packages may upgrade.
- Select a virtual package automatically only when it has one provider.
- Install in dependency order; cycles degrade to stable name order.
- Remove dependents first; `autoremove` recursively removes orphaned automatic dependencies.

An installation plan is validated as a whole, staged and backed up, then atomically updates `/var/lib/pkg/status`. Failure replays the journal in reverse. Upgrades delete old files only after every new file is in place. Unowned files and cross-package conflicts reject overwrites by default.

State and caches live in the guest VFS and persist with filesystem snapshots.

## Production and Go Modules

Package authoring and `Packages` generation are release-system responsibilities and are not exposed as guest shell commands. Release builders use the `PackageArchive.build`, `RepositoryIndex.render`, and `PackageManager` authoring APIs. Golden fixtures pin the archive and index encodings byte for byte.

The Go toolchain does not connect directly to `GOPROXY`. Packages may install source into `GOMODCACHE`, where `go build` resolves it by the longest module prefix.

## Trust Boundary

HTTP plus SHA-256 currently provides **integrity**, not origin authentication. The 1.0 contract is limited to user-controlled teaching, experimental, or in-app virtual networks and must not be presented as safe for arbitrary public package sources. A public-network contract would additionally require repository signing, key policy, and HTTPS; see the [product roadmap](roadmap.md).
