/// The Swiftix-native command-line front end for package management.

import Swiftix

enum PackageCommands {

    static func register(in registry: CommandRegistry) {
        registry.register(pkgCommand())
    }

    private static func pkgCommand() -> Command {
        Command(
            name: "pkg",
            summary: "manage packages",
            category: .system,
            asyncRun: { context, argv in
                await run(context: context) {
                    try await dispatch(context, arguments: Array(argv.dropFirst()))
                }
            })
    }

    private static func run(
        context: ProcessContext,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            context.exit(0)
        } catch let error as PackageError {
            _ = context.write(2, Array("pkg: \(error.message)\n".utf8))
            context.exit(error.exitCode)
        } catch {
            _ = context.write(2, Array("pkg: \(error)\n".utf8))
            context.exit(1)
        }
    }

    private enum Subcommand {
        case update, install, reinstall, remove, purge, autoremove, upgrade, fullUpgrade
        case list, search, info, files, owner, arch, clean
    }

    private struct Invocation {
        var command: Subcommand?
        var operands: [String] = []
        var options = PackageOptions()
        var listFilter: PackageManager.ListFilter = .all
        var showHelp = false
        var showVersion = false
    }

    private static func dispatch(_ context: ProcessContext, arguments: [String]) async throws {
        let invocation = try parse(arguments)
        if invocation.showHelp {
            context.print(usage)
            return
        }
        if invocation.showVersion {
            context.print(SwiftixPackages.toolVersion + "\n")
            return
        }
        guard let command = invocation.command else { throw PackageError.usage(usage) }

        let manager = PackageManager(context: context)
        switch command {
        case .update:
            try await manager.update(options: invocation.options)
        case .install:
            try await manager.install(invocation.operands, options: invocation.options)
        case .reinstall:
            var options = invocation.options
            options.reinstall = true
            try await manager.install(invocation.operands, options: options)
        case .remove, .purge:
            try await manager.remove(invocation.operands, options: invocation.options)
        case .autoremove:
            try await manager.autoremove(options: invocation.options)
        case .upgrade, .fullUpgrade:
            try await manager.upgrade(options: invocation.options)
        case .list:
            try manager.list(invocation.listFilter)
        case .search:
            guard invocation.operands.count == 1 else {
                throw PackageError.usage("search requires one search term")
            }
            try manager.search(invocation.operands[0])
        case .info:
            try manager.show(invocation.operands)
        case .files:
            guard !invocation.operands.isEmpty else {
                throw PackageError.usage("files requires at least one package name")
            }
            for name in invocation.operands { try manager.files(name) }
        case .owner:
            guard invocation.operands.count == 1 else {
                throw PackageError.usage("owner requires one pathname")
            }
            let path = invocation.operands[0]
            guard let owner = try manager.installedDatabase().owner(ofFile: path) else {
                throw PackageError.packageNotFound(name: path)
            }
            context.print("\(owner): \(path)\n")
        case .arch:
            guard invocation.operands.isEmpty else {
                throw PackageError.usage("arch takes no operands")
            }
            context.print(manager.hostArchitecture + "\n")
        case .clean:
            try manager.clean()
        }
    }

    private static func parse(_ arguments: [String]) throws -> Invocation {
        var invocation = Invocation()
        for argument in arguments {
            switch argument {
            case "-h", "--help", "help": invocation.showHelp = true
            case "-v", "--version": invocation.showVersion = true
            case "-y", "--yes", "--assume-yes": invocation.options.assumeYes = true
            case "-s", "--simulate", "--dry-run": invocation.options.dryRun = true
            case "-q", "--quiet": invocation.options.quiet = true
            case "--no-deps": invocation.options.withDependencies = false
            case "--reinstall": invocation.options.reinstall = true
            case "--force-overwrite": invocation.options.forceOverwrite = true
            case "--force-depends": invocation.options.forceDepends = true
            case "--installed": invocation.listFilter = .installed
            case "--upgradable", "--upgradeable": invocation.listFilter = .upgradable
            default:
                if argument.hasPrefix("-") { throw PackageError.unknownOption(argument) }
                if invocation.command == nil {
                    guard let command = subcommand(argument) else {
                        throw PackageError.usage("unknown command '\(argument)'")
                    }
                    invocation.command = command
                } else {
                    invocation.operands.append(argument)
                }
            }
        }
        return invocation
    }

    private static func subcommand(_ value: String) -> Subcommand? {
        switch value {
        case "update": return .update
        case "install": return .install
        case "reinstall": return .reinstall
        case "remove": return .remove
        case "purge": return .purge
        case "autoremove": return .autoremove
        case "upgrade": return .upgrade
        case "full-upgrade": return .fullUpgrade
        case "list": return .list
        case "search": return .search
        case "info": return .info
        case "files": return .files
        case "owner": return .owner
        case "arch": return .arch
        case "clean": return .clean
        default: return nil
        }
    }

    private static let usage = """
        pkg: usage: pkg <command> [options] [package...]

        commands:
          update                  retrieve package lists
          install <package...>    install or upgrade packages
          reinstall <package...>  reinstall packages
          remove <package...>     remove packages
          purge <package...>      remove packages and configuration
          autoremove              remove unused dependencies
          upgrade                 upgrade installed packages without removals
          full-upgrade            upgrade the system
          list                    list packages
          search <term>           search package descriptions
          info <package...>       show package details
          files <package...>      list files installed by packages
          owner <pathname>        find the package owning a path
          arch                    print the native package architecture
          clean                   remove downloaded package files

        options:
          -y, --assume-yes        answer yes to prompts
          -s, --simulate          show the plan without changing the system
          -q, --quiet             reduce progress output
          --no-deps               do not resolve or enforce dependencies
          --installed             limit `list` to installed packages
          --upgradable            limit `list` to upgradable packages

        repositories are configured in /etc/pkg/sources.list:
          repo http://packages.example/repo ./

        """
}
