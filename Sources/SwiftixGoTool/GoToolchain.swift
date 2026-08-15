/// User-facing `go` command implemented entirely through Swiftix public syscalls.

import Swiftix
import SwiftixGo
import SwiftixGoRuntime

public enum GoToolchain {
    public static let languageVersion = "1.24"
    public static let toolVersion = "go1.24-swiftix.0.3"

    public static func register(in registry: CommandRegistry) {
        registry.register(command())
        registry.register(gofmtCommand())
        GoExecutableLoader.register(in: registry)
    }

    public static func command() -> Command {
        Command(
            name: "go",
            summary: "build and run Swiftix Go programs",
            category: .system
        ) { context, arguments in
            run(context, arguments: arguments)
        }
    }

    public static func gofmtCommand() -> Command {
        Command(
            name: "gofmt",
            summary: "format Go source code",
            category: .system,
            asyncRun: { context, arguments in
                await runGofmt(context, arguments: Array(arguments.dropFirst()))
            })
    }

    public static func run(_ context: any GoToolContext, arguments: [String]) {
        guard arguments.count > 1 else {
            writeError(context, usage)
            context.exit(2)
            return
        }

        switch arguments[1] {
        case "version":
            guard arguments.count == 2 else {
                fail(context, "go version: accepts no arguments", status: 2)
                return
            }
            context.print(
                "go version \(toolVersion) \(GoExecutableImage.targetOS)/\(GoExecutableImage.targetArchitecture)\n")
            context.exit(0)
        case "env":
            runEnv(context, arguments: Array(arguments.dropFirst(2)))
        case "mod":
            runMod(context, arguments: Array(arguments.dropFirst(2)))
        case "run":
            runSources(context, arguments: Array(arguments.dropFirst(2)))
        case "build":
            runBuild(context, arguments: Array(arguments.dropFirst(2)))
        case "clean":
            runClean(context, arguments: Array(arguments.dropFirst(2)))
        case "install":
            runInstall(context, arguments: Array(arguments.dropFirst(2)))
        case "fmt":
            runFormat(context, arguments: Array(arguments.dropFirst(2)))
        case "test":
            runTest(context, arguments: Array(arguments.dropFirst(2)))
        case "help":
            context.print(usage)
            context.exit(0)
        default:
            fail(
                context,
                "go \(arguments[1]): command is not supported by this Swiftix Go checkpoint",
                status: 2)
        }
    }

    private static func runEnv(_ context: any GoToolContext, arguments: [String]) {
        let values = environment(context)
        if arguments.isEmpty {
            for name in environmentOrder {
                context.print("\(name)='\(values[name] ?? "")'\n")
            }
            context.exit(0)
            return
        }

        for name in arguments {
            guard let value = values[name] else {
                fail(context, "go: unknown go command variable \(name)", status: 1)
                return
            }
            context.print(value + "\n")
        }
        context.exit(0)
    }

    private static func runMod(_ context: any GoToolContext, arguments: [String]) {
        guard arguments.count == 2, arguments[0] == "init" else {
            fail(context, "go mod: usage: go mod init module-path", status: 2)
            return
        }
        let modulePath = arguments[1]
        guard !modulePath.isEmpty,
            !modulePath.contains(where: { $0.isWhitespace || $0.isNewline })
        else {
            fail(context, "go: malformed module path \"\(modulePath)\"", status: 1)
            return
        }
        guard context.stat("go.mod") == nil else {
            fail(context, "go: go.mod already exists", status: 1)
            return
        }

        let contents = "module \(modulePath)\n\ngo \(languageVersion)\n"
        do {
            let descriptor = try context.openFile(
                "go.mod", flags: [.create, .exclusive], access: .writeOnly)
            defer { try? context.closeFile(descriptor) }
            _ = try context.writeFile(descriptor, Array(contents.utf8))
            context.print("go: creating new go.mod: module \(modulePath)\n")
            context.exit(0)
        } catch {
            fail(context, "go: creating go.mod: \(String(describing: error))", status: 1)
        }
    }

    private static func runSources(_ context: any GoToolContext, arguments: [String]) {
        do {
            let options = try parseRunOptions(arguments)
            let executable = try compile(context, arguments: options.inputs)
            let programName = defaultBuildOutput(context, inputs: options.inputs)
            let exitCode = try context.runGoExecutable(
                executable,
                arguments: [programName] + options.arguments
            ) { text in
                _ = context.write(1, Array(text.utf8))
            }
            context.exit(exitCode)
        } catch {
            fail(context, String(describing: error), status: 1)
        }
    }

    private static func runBuild(_ context: any GoToolContext, arguments: [String]) {
        do {
            let options = try parseBuildOptions(context, arguments: arguments)
            let executable = try compile(context, arguments: options.inputs)
            try writeExecutable(
                context,
                executable: executable,
                output: options.output,
                operation: "build")
            context.exit(0)
        } catch {
            fail(context, String(describing: error), status: 1)
        }
    }

    private static func runClean(_ context: any GoToolContext, arguments: [String]) {
        guard arguments == ["-cache"] else {
            fail(context, "go clean: only -cache is supported in this checkpoint", status: 2)
            return
        }
        do {
            if let root = try buildCacheRoot(context) {
                try GoBuildCache.clear(context, root: root)
            }
            context.exit(0)
        } catch {
            fail(context, String(describing: error), status: 1)
        }
    }

    private static func runInstall(_ context: any GoToolContext, arguments: [String]) {
        do {
            let inputs = try parseInstallInputs(arguments)
            let goBin = environment(context)["GOBIN"] ?? "/home/user/go/bin"
            guard goBin.hasPrefix("/") else {
                throw GoToolError.invalidInstallArguments(
                    "go: cannot install, GOBIN must be an absolute path")
            }
            let executable = try compile(context, arguments: inputs)
            if let status = context.stat(goBin) {
                guard status.isDirectory else {
                    throw GoToolError.invalidInstallArguments(
                        "go: cannot install, GOBIN \"\(goBin)\" is not a directory")
                }
            } else if !context.mkdir(goBin) {
                throw GoToolError.invalidInstallArguments(
                    "go: cannot create GOBIN \"\(goBin)\"")
            }

            let output = join(goBin, defaultBuildOutput(context, inputs: inputs))
            try writeExecutable(
                context,
                executable: executable,
                output: output,
                operation: "install")
            context.exit(0)
        } catch {
            fail(context, String(describing: error), status: 1)
        }
    }

    private static func runFormat(_ context: any GoToolContext, arguments: [String]) {
        do {
            let targets = arguments.isEmpty ? ["."] : arguments
            let selection = try formatSelection(context, arguments: targets)
            let formatted = try prepareFormattedFiles(context, paths: selection.paths)
            try writeFormattedFiles(context, files: formatted)

            if selection.reportPackages {
                let directories = Set(
                    formatted.lazy.filter(\.changed).map { directoryName($0.path) })
                for directory in directories.sorted() {
                    context.print((packagePath(context, directory: directory) ?? directory) + "\n")
                }
            } else {
                for file in formatted where file.changed { context.print(file.path + "\n") }
            }
            context.exit(0)
        } catch {
            fail(context, String(describing: error), status: 1)
        }
    }

    private static func runTest(_ context: any GoToolContext, arguments: [String]) {
        do {
            let directories: [String]
            switch arguments {
            case [], ["."]:
                directories = ["."]
            case ["./..."]:
                directories = try recursivePackageDirectories(context)
            default:
                throw GoToolError.invalidBuildArguments(
                    "go test: only '.', './...', or the current package is supported")
            }
            var failed = false
            for directory in directories {
                let packageName = packagePath(context, directory: directory) ?? directory
                if try !runTestPackage(
                    context, directory: directory, packageName: packageName)
                {
                    failed = true
                }
            }
            if failed { context.print("FAIL\n") }
            context.exit(failed ? 1 : 0)
        } catch {
            fail(context, String(describing: error), status: 1)
        }
    }

    private static func runTestPackage(
        _ context: any GoToolContext,
        directory: String,
        packageName: String
    ) throws -> Bool {
        guard let entries = context.listDirectory(directory) else {
            throw GoToolError.invalidModule("go test: cannot read \(directory)")
        }
        let testNames = entries.filter {
            $0.hasSuffix("_test.go") && !$0.hasSuffix("/")
        }.sorted()
        let sourceNames = entries.filter {
            $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") && !$0.hasSuffix("/")
                && !$0.hasPrefix(".") && !$0.hasPrefix("_")
        }.sorted()
        guard !testNames.isEmpty else {
            context.print("?   \t\(packageName)\t[no test files]\n")
            return true
        }
        let paths = sourceNames + testNames
        let originalSources = try paths.map { name -> GoSourceFile in
            let path = childPath(directory, name)
            let bytes = try readFile(
                context, path: path, maximumBytes: maximumSourceBytes)
            return GoSourceFile(
                path: path, text: String(decoding: bytes, as: UTF8.self))
        }
        let parsed = try originalSources.map(GoParser.parse)
        let testFunctions = parsed.flatMap(\.functions).filter { function in
            guard function.receiver == nil,
                function.name.hasPrefix("Test"), function.name.count > 4
            else { return false }
            if function.parameters.isEmpty { return true }
            guard function.parameters.count == 1,
                case .pointer(let pointee, _) = function.parameters[0].type,
                case .named("testing.T", _) = pointee
            else { return false }
            return true
        }
        guard !testFunctions.isEmpty else {
            context.print("?   \t\(packageName)\t[no test functions]\n")
            return true
        }

        let mainSources = try originalSources.compactMap { source -> GoSourceFile? in
            let file = try GoParser.parse(source)
            if file.functions.contains(where: { $0.name == "main" }) { return nil }
            return GoSourceFile(
                path: source.path,
                text: replacingPackageClause(in: source.text, package: file.packageName))
        }
        let absoluteDirectory = directory == "."
            ? context.currentDirectory
            : join(context.currentDirectory, directory)
        let graph = try loadPackageGraph(context, rootDirectory: absoluteDirectory)
        let dependencyBuild = try compileDependencies(graph)
        var packageFailed = false
        for testFunction in testFunctions {
            let arguments = testFunction.parameters.isEmpty ? "" : "nil"
            let runner = GoSourceFile(
                path: childPath(directory, "$test_runner.go"),
                text: "package main\nfunc main() {\n    \(testFunction.name)(\(arguments))\n}\n")
            var output = ""
            do {
                let executable = try GoCompiler.compile(
                    sources: mainSources + [runner],
                    importedPackages: dependencyBuild.packages,
                    packageOrder: dependencyBuild.order)
                let exitCode = try context.runGoExecutable(
                    executable,
                    arguments: [testFunction.name]
                ) { output += $0 }
                writeTestOutput(
                    context, output: output, rootTest: testFunction.name)
                if exitCode == 0 {
                    context.print("--- PASS: \(testFunction.name)\n")
                } else {
                    packageFailed = true
                    context.print("--- FAIL: \(testFunction.name)\n")
                    context.print("    test exited with status \(exitCode)\n")
                }
            } catch {
                packageFailed = true
                writeTestOutput(
                    context, output: output, rootTest: testFunction.name)
                context.print("--- FAIL: \(testFunction.name)\n")
                let message = String(describing: error)
                if message != "test failed" {
                    context.print("    \(message)\n")
                }
            }
        }
        if packageFailed {
            context.print("FAIL\t\(packageName)\n")
            return false
        }
        context.print("ok  \t\(packageName)\n")
        return true
    }

    private static func writeTestOutput(
        _ context: any GoToolContext,
        output: String,
        rootTest: String
    ) {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- PASS: ") || line.hasPrefix("--- FAIL: ") {
                let fields = line.split(separator: ":", maxSplits: 1)
                if fields.count == 2 {
                    let name = fields[1].drop(while: { $0 == " " || $0 == "\t" })
                    context.print("\(fields[0]): \(rootTest)/\(name)\n")
                }
            } else if !line.isEmpty {
                context.print(String(line) + "\n")
            }
        }
    }

    private static func replacingPackageClause(
        in text: String,
        package: String
    ) -> String {
        guard let range = text.firstRange(of: "package " + package) else { return text }
        var result = text
        result.replaceSubrange(range, with: "package main")
        return result
    }

    public static func runGofmt(
        _ context: any GoToolContext,
        arguments: [String]
    ) async {
        do {
            let options = try parseGofmtOptions(arguments)
            if options.showHelp {
                context.print(gofmtUsage)
                context.exit(0)
                return
            }
            if options.paths.isEmpty {
                guard !options.write else {
                    throw GoToolError.invalidFormatArguments(
                        "gofmt: cannot use -w with standard input")
                }
                let bytes = try await readStandardInput(context, maximumBytes: maximumSourceBytes)
                let text = try decodeSource(bytes, path: "<standard input>")
                let source = GoSourceFile(
                    path: "<standard input>",
                    text: text)
                let transformed = try transform(
                    source,
                    simplify: options.simplify,
                    rewriteRule: options.rewriteRule)
                let formatted = try GoFormatter.format(transformed)
                if options.list, text != formatted {
                    context.print(source.path + "\n")
                }
                if options.diff {
                    context.print(
                        GoSourceDiff.unified(
                            original: text,
                            formatted: formatted,
                            path: source.path))
                } else if !options.list {
                    context.print(formatted)
                }
            } else {
                let paths = try gofmtSourcePaths(context, arguments: options.paths)
                let formatted = try prepareFormattedFiles(
                    context,
                    paths: paths,
                    simplify: options.simplify,
                    rewriteRule: options.rewriteRule)
                if options.list {
                    for file in formatted where file.changed { context.print(file.path + "\n") }
                }
                if options.diff {
                    for file in formatted where file.changed {
                        context.print(
                            GoSourceDiff.unified(
                                original: file.original,
                                formatted: file.formatted,
                                path: file.path))
                    }
                }
                if options.write {
                    try writeFormattedFiles(context, files: formatted)
                } else if !options.diff && !options.list {
                    for file in formatted { context.print(file.formatted) }
                }
            }
            context.exit(0)
        } catch {
            fail(context, String(describing: error), status: 2)
        }
    }

    private static func compile(
        _ context: any GoToolContext,
        arguments: [String]
    ) throws -> GoExecutable {
        guard !arguments.isEmpty else { throw GoToolError.noGoFilesListed }
        let cacheRoot = try buildCacheRoot(context)
        let graph = arguments == ["."] ? try loadPackageGraph(context) : nil
        let sources: [GoSourceFile]
        if let graph {
            sources = graph.order.flatMap { graph.packages[$0]?.sources ?? [] }
        } else {
            let paths = try sourcePaths(context, arguments: arguments)
            sources = try paths.map { path -> GoSourceFile in
                let bytes = try readFile(context, path: path, maximumBytes: maximumSourceBytes)
                return GoSourceFile(path: path, text: String(decoding: bytes, as: UTF8.self))
            }
        }
        let build = {
            if let graph { return try compilePackageGraph(graph) }
            return try GoCompiler.compile(sources: sources)
        }
        guard let cacheRoot else {
            return try build()
        }

        let moduleFile = try findModule(context).map {
            try readFile(context, path: $0, maximumBytes: maximumSourceBytes)
        }
        let key = GoBuildCache.key(
            toolVersion: toolVersion,
            languageVersion: languageVersion,
            sources: sources,
            moduleFile: moduleFile)
        if let executable = GoBuildCache.load(context, root: cacheRoot, key: key) {
            return executable
        }
        let executable = try build()
        try GoBuildCache.store(
            context,
            root: cacheRoot,
            key: key,
            executable: executable)
        return executable
    }

    private static func loadPackageGraph(
        _ context: any GoToolContext,
        rootDirectory requestedRoot: String? = nil
    ) throws -> PackageGraph {
        guard let moduleFile = findModule(context) else {
            throw GoToolError.invalidModule(
                "go: cannot find main module; see 'go help modules'")
        }
        try validateModule(context, path: moduleFile)
        let moduleBytes = try readFile(
            context, path: moduleFile, maximumBytes: maximumSourceBytes)
        let moduleText = String(decoding: moduleBytes, as: UTF8.self)
        guard let moduleName = moduleText.split(separator: "\n").compactMap({ line -> String? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.first == "module" && fields.count >= 2 ? String(fields[1]) : nil
        }).first else {
            throw GoToolError.invalidModule("go: missing module declaration")
        }
        let moduleRoot = parent(of: moduleFile)
        let rootDirectory = requestedRoot ?? context.currentDirectory
        let rootPath = packagePathInModule(
            moduleName: moduleName, moduleRoot: moduleRoot, directory: rootDirectory)

        var packages: [String: PackageNode] = [:]
        var order: [String] = []
        var visiting: [String] = []
        var visited: Set<String> = []

        func visit(_ importPath: String, directory: String) throws {
            if let cycleStart = visiting.firstIndex(of: importPath) {
                let cycle = Array(visiting[cycleStart...]) + [importPath]
                throw GoToolError.invalidModule(
                    "package \(cycle.joined(separator: "\n\timports ")): import cycle not allowed")
            }
            if visited.contains(importPath) { return }
            visiting.append(importPath)
            defer { _ = visiting.popLast() }

            guard let entries = context.listDirectory(directory) else {
                throw GoToolError.invalidModule("go: cannot read package \(importPath)")
            }
            let paths = entries.filter {
                $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") && !$0.hasSuffix("/")
                    && !$0.hasPrefix(".") && !$0.hasPrefix("_")
            }.sorted()
            guard !paths.isEmpty else {
                throw GoToolError.noGoFiles(directory: directory)
            }
            let sources = try paths.map { name -> GoSourceFile in
                let path = join(directory, name)
                let bytes = try readFile(
                    context, path: path, maximumBytes: maximumSourceBytes)
                return GoSourceFile(
                    path: path, text: String(decoding: bytes, as: UTF8.self))
            }
            let files = try sources.map(GoParser.parse)
            let imports = Array(Set(files.flatMap(\.imports).map(\.path))).sorted()
            let localImports = try imports.compactMap { dependency -> (String, String)? in
                if GoTypeChecker.supportedStandardPackages.contains(dependency) {
                    return nil
                }
                if dependency == moduleName || dependency.hasPrefix(moduleName + "/") {
                    let suffix = dependency == moduleName
                        ? ""
                        : String(dependency.dropFirst(moduleName.count + 1))
                    let dependencyDirectory = suffix.isEmpty
                        ? moduleRoot
                        : join(moduleRoot, suffix)
                    return (dependency, dependencyDirectory)
                }
                // A package outside this module resolves through the module cache
                // (`GOMODCACHE`). The cache is populated by the system package
                // manager (`pkg install …`), which fetches module sources over the
                // network — the toolchain itself still performs no downloads, it
                // just no longer refuses to look outside the main module.
                guard let cached = moduleCacheDirectory(context, importPath: dependency) else {
                    throw GoToolError.invalidModule(
                        "package \(dependency) is not available: no source in "
                            + "\(moduleCacheRoot(context)); install the module "
                            + "('pkg install <package>') or add a local replace")
                }
                return (dependency, cached)
            }
            packages[importPath] = PackageNode(
                path: importPath,
                directory: directory,
                sources: sources,
                imports: localImports.map(\.0))
            for (dependency, dependencyDirectory) in localImports {
                try visit(dependency, directory: dependencyDirectory)
            }
            visited.insert(importPath)
            order.append(importPath)
        }

        try visit(rootPath, directory: rootDirectory)
        return PackageGraph(
            moduleName: moduleName,
            rootPath: rootPath,
            packages: packages,
            order: order)
    }

    private static func compilePackageGraph(_ graph: PackageGraph) throws -> GoExecutable {
        let dependencyBuild = try compileDependencies(graph)
        guard let root = graph.packages[graph.rootPath] else {
            throw GoToolError.invalidModule("go: root package is missing")
        }
        return try GoCompiler.compile(
            sources: root.sources,
            importedPackages: dependencyBuild.packages,
            packageOrder: dependencyBuild.order)
    }

    private static func compileDependencies(
        _ graph: PackageGraph
    ) throws -> (packages: [String: GoCompiledPackage], order: [String]) {
        var compiled: [String: GoCompiledPackage] = [:]
        var globalOffset = 0
        for path in graph.order where path != graph.rootPath {
            guard let node = graph.packages[path] else { continue }
            let dependencies = Dictionary(
                uniqueKeysWithValues: node.imports.compactMap { dependency in
                    compiled[dependency].map { (dependency, $0) }
                })
            let package = try GoCompiler.compilePackage(
                sources: node.sources,
                importedPackages: dependencies,
                globalOffset: globalOffset)
            compiled[path] = package
            globalOffset += package.globalCount
        }
        let packageOrder = graph.order.filter { $0 != graph.rootPath }
        return (compiled, packageOrder)
    }

    private static func packagePathInModule(
        moduleName: String,
        moduleRoot: String,
        directory: String
    ) -> String {
        guard directory != moduleRoot else { return moduleName }
        let prefix = moduleRoot == "/" ? "/" : moduleRoot + "/"
        guard directory.hasPrefix(prefix) else { return moduleName }
        return moduleName + "/" + String(directory.dropFirst(prefix.count))
    }

    private static func formatSelection(
        _ context: any GoToolContext,
        arguments: [String]
    ) throws -> FormatSelection {
        if arguments == ["."] {
            guard let entries = context.listDirectory(".") else {
                throw GoToolError.invalidFormatArguments("go fmt: cannot read current directory")
            }
            let paths = entries.filter(isImplicitGoSource).sorted()
            guard !paths.isEmpty else {
                throw GoToolError.noGoFiles(directory: context.currentDirectory)
            }
            return FormatSelection(paths: paths, reportPackages: true)
        }
        if arguments == ["./..."] {
            return FormatSelection(
                paths: try recursiveGoSourcePaths(context),
                reportPackages: true)
        }
        if let flag = arguments.first(where: { $0.hasPrefix("-") }) {
            throw GoToolError.invalidFormatArguments("go fmt: unsupported flag \(flag)")
        }
        guard arguments.allSatisfy({ $0.hasSuffix(".go") }) else {
            throw GoToolError.invalidFormatArguments(
                "go fmt: only the current package or explicit .go files are supported")
        }
        return FormatSelection(paths: arguments, reportPackages: false)
    }

    private static func recursiveGoSourcePaths(_ context: any GoToolContext) throws -> [String] {
        guard let moduleFile = findModule(context) else {
            throw GoToolError.invalidModule(
                "go: cannot match \"./...\" without a main module")
        }
        try validateModule(context, path: moduleFile)

        var paths: [String] = []
        var pendingDirectories = ["."]
        var index = 0
        while index < pendingDirectories.count {
            let directory = pendingDirectories[index]
            index += 1
            if directory != ".", context.stat(childPath(directory, "go.mod")) != nil {
                continue
            }
            guard let entries = context.listDirectory(directory) else {
                throw GoToolError.invalidFormatArguments(
                    "go fmt: cannot read directory \(directory)")
            }
            for entry in entries {
                if entry.hasSuffix("/") {
                    let name = String(entry.dropLast())
                    if !shouldSkipPackageDirectory(name) {
                        pendingDirectories.append(childPath(directory, name))
                    }
                } else if isImplicitGoSource(entry) {
                    paths.append(childPath(directory, entry))
                }
            }
        }
        guard !paths.isEmpty else {
            throw GoToolError.invalidFormatArguments(
                "go: warning: \"./...\" matched no packages")
        }
        return paths.sorted()
    }

    private static func recursivePackageDirectories(
        _ context: any GoToolContext
    ) throws -> [String] {
        guard let moduleFile = findModule(context) else {
            throw GoToolError.invalidModule(
                "go: cannot match \"./...\" without a main module")
        }
        try validateModule(context, path: moduleFile)
        var directories: [String] = []
        var pending = ["."]
        var index = 0
        while index < pending.count {
            let directory = pending[index]
            index += 1
            if directory != ".", context.stat(childPath(directory, "go.mod")) != nil {
                continue
            }
            guard let entries = context.listDirectory(directory) else {
                throw GoToolError.invalidModule("go test: cannot read \(directory)")
            }
            if entries.contains(where: {
                $0.hasSuffix(".go") && !$0.hasSuffix("/")
                    && !$0.hasPrefix(".") && !$0.hasPrefix("_")
            }) {
                directories.append(directory)
            }
            for entry in entries where entry.hasSuffix("/") {
                let name = String(entry.dropLast())
                if !shouldSkipPackageDirectory(name) {
                    pending.append(childPath(directory, name))
                }
            }
        }
        return directories.sorted()
    }

    private static func gofmtSourcePaths(
        _ context: any GoToolContext,
        arguments: [String]
    ) throws -> [String] {
        var paths: [String] = []
        for argument in arguments {
            guard let status = context.stat(argument) else {
                throw GoToolError.invalidFormatArguments(
                    "gofmt: \(argument): no such file or directory")
            }
            guard status.isDirectory else {
                paths.append(argument)
                continue
            }

            var pendingDirectories = [trimDirectorySeparator(argument)]
            var index = 0
            while index < pendingDirectories.count {
                let directory = pendingDirectories[index]
                index += 1
                guard let entries = context.listDirectory(directory) else {
                    throw GoToolError.invalidFormatArguments(
                        "gofmt: cannot read directory \(directory)")
                }
                for entry in entries {
                    if entry.hasSuffix("/") {
                        pendingDirectories.append(
                            childPath(directory, String(entry.dropLast())))
                    } else if entry.hasSuffix(".go"), !entry.hasPrefix(".") {
                        paths.append(childPath(directory, entry))
                    }
                }
            }
        }
        return paths
    }

    private static func isImplicitGoSource(_ name: String) -> Bool {
        name.hasSuffix(".go") && !name.hasPrefix(".") && !name.hasPrefix("_")
            && !name.hasSuffix("/")
    }

    private static func shouldSkipPackageDirectory(_ name: String) -> Bool {
        name == "vendor" || name == "testdata" || name.hasPrefix(".") || name.hasPrefix("_")
    }

    private static func childPath(_ directory: String, _ name: String) -> String {
        if directory == "." { return name }
        if directory == "/" { return "/" + name }
        return directory + "/" + name
    }

    private static func trimDirectorySeparator(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func directoryName(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "." }
        let directory = String(path[..<separator])
        return directory.isEmpty ? "." : directory
    }

    private static func prepareFormattedFiles(
        _ context: any GoToolContext,
        paths: [String],
        simplify: Bool = false,
        rewriteRule: String? = nil
    ) throws -> [FormattedFile] {
        try paths.map { path in
            let bytes: [UInt8]
            do {
                bytes = try readFile(context, path: path, maximumBytes: maximumSourceBytes)
            } catch let error as GoToolError {
                throw error
            } catch {
                throw GoToolError.invalidFormatArguments(
                    "gofmt: \(path): \(String(describing: error))")
            }
            let original = try decodeSource(bytes, path: path)
            let source = try transform(
                GoSourceFile(path: path, text: original),
                simplify: simplify,
                rewriteRule: rewriteRule)
            let formatted = try GoFormatter.format(source)
            return FormattedFile(
                path: path,
                original: original,
                formatted: formatted,
                changed: original != formatted)
        }
    }

    private static func transform(
        _ source: GoSourceFile,
        simplify: Bool,
        rewriteRule: String?
    ) throws -> GoSourceFile {
        var transformed = source
        if let rewriteRule {
            transformed = try GoSourceRewriter.rewrite(transformed, rule: rewriteRule)
        }
        if simplify {
            transformed = try GoSourceRewriter.simplify(transformed)
        }
        return transformed
    }

    private static func writeFormattedFiles(
        _ context: any GoToolContext,
        files: [FormattedFile]
    ) throws {
        for file in files where file.changed {
            do {
                let descriptor = try context.openFile(
                    file.path,
                    flags: [.truncate],
                    access: .writeOnly)
                defer { try? context.closeFile(descriptor) }
                let bytes = Array(file.formatted.utf8)
                guard try context.writeFile(descriptor, bytes) == bytes.count else {
                    throw GoToolError.invalidFormatArguments(
                        "gofmt: \(file.path): short write")
                }
            } catch let error as GoToolError {
                throw error
            } catch {
                throw GoToolError.invalidFormatArguments(
                    "gofmt: \(file.path): \(String(describing: error))")
            }
        }
    }

    private static func packagePath(
        _ context: any GoToolContext,
        directory: String
    ) -> String? {
        guard let moduleFile = findModule(context),
            let bytes = try? readFile(
                context,
                path: moduleFile,
                maximumBytes: maximumSourceBytes)
        else {
            return nil
        }
        let moduleText = String(decoding: bytes, as: UTF8.self)
        var moduleName: String?
        for line in moduleText.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "module", fields.count >= 2 {
                moduleName = String(fields[1])
                break
            }
        }
        guard let moduleName else { return nil }

        let root = parent(of: moduleFile)
        let packageDirectory =
            directory == "." ? context.currentDirectory : join(context.currentDirectory, directory)
        guard packageDirectory != root else { return moduleName }
        let prefix = root == "/" ? "/" : root + "/"
        guard packageDirectory.hasPrefix(prefix) else { return moduleName }
        return moduleName + "/" + String(packageDirectory.dropFirst(prefix.count))
    }

    private static func parseGofmtOptions(_ arguments: [String]) throws -> GofmtOptions {
        var write = false
        var diff = false
        var list = false
        var showHelp = false
        var simplify = false
        var rewriteRule: String?
        var paths: [String] = []
        var acceptsFlags = true
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if acceptsFlags, argument == "--" {
                acceptsFlags = false
            } else if acceptsFlags, argument == "-w" {
                write = true
            } else if acceptsFlags, argument == "-d" {
                diff = true
            } else if acceptsFlags, argument == "-l" {
                list = true
            } else if acceptsFlags, argument == "-s" {
                simplify = true
            } else if acceptsFlags, argument == "-r" {
                index += 1
                guard index < arguments.count else {
                    throw GoToolError.invalidFormatArguments(
                        "gofmt: flag needs an argument: -r\n\(gofmtUsage)")
                }
                rewriteRule = arguments[index]
            } else if acceptsFlags, argument.hasPrefix("-r=") {
                rewriteRule = String(argument.dropFirst(3))
            } else if acceptsFlags, argument == "-h" || argument == "-help" {
                showHelp = true
            } else if acceptsFlags, argument.hasPrefix("-") {
                throw GoToolError.invalidFormatArguments(
                    "gofmt: flag provided but not defined: \(argument)\n\(gofmtUsage)")
            } else {
                paths.append(argument)
            }
            index += 1
        }
        return GofmtOptions(
            write: write,
            diff: diff,
            list: list,
            showHelp: showHelp,
            simplify: simplify,
            rewriteRule: rewriteRule,
            paths: paths)
    }

    private static func readStandardInput(
        _ context: any GoToolContext,
        maximumBytes: Int
    ) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count <= maximumBytes {
            let capacity = maximumBytes + 1 - bytes.count
            let chunk = try await context.readStandardInput(upTo: min(4_096, capacity))
            if chunk.isEmpty { break }
            bytes.append(contentsOf: chunk)
        }
        guard bytes.count <= maximumBytes else {
            throw GoToolError.sourceTooLarge("<standard input>")
        }
        return bytes
    }

    private static func decodeSource(_ bytes: [UInt8], path: String) throws -> String {
        guard isValidUTF8(bytes) else {
            throw GoToolError.invalidFormatArguments(
                "gofmt: \(path): invalid UTF-8 encoding")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        func isContinuation(_ index: Int) -> Bool {
            index < bytes.count && bytes[index] >= 0x80 && bytes[index] <= 0xBF
        }
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            switch first {
            case 0x00...0x7F:
                index += 1
            case 0xC2...0xDF:
                guard isContinuation(index + 1) else { return false }
                index += 2
            case 0xE0:
                guard index + 2 < bytes.count, bytes[index + 1] >= 0xA0,
                    bytes[index + 1] <= 0xBF, isContinuation(index + 2)
                else { return false }
                index += 3
            case 0xE1...0xEC, 0xEE...0xEF:
                guard isContinuation(index + 1), isContinuation(index + 2) else { return false }
                index += 3
            case 0xED:
                guard index + 2 < bytes.count, bytes[index + 1] >= 0x80,
                    bytes[index + 1] <= 0x9F, isContinuation(index + 2)
                else { return false }
                index += 3
            case 0xF0:
                guard index + 3 < bytes.count, bytes[index + 1] >= 0x90,
                    bytes[index + 1] <= 0xBF, isContinuation(index + 2),
                    isContinuation(index + 3)
                else { return false }
                index += 4
            case 0xF1...0xF3:
                guard isContinuation(index + 1), isContinuation(index + 2),
                    isContinuation(index + 3)
                else { return false }
                index += 4
            case 0xF4:
                guard index + 3 < bytes.count, bytes[index + 1] >= 0x80,
                    bytes[index + 1] <= 0x8F, isContinuation(index + 2),
                    isContinuation(index + 3)
                else { return false }
                index += 4
            default:
                return false
            }
        }
        return true
    }

    private static func sourcePaths(
        _ context: any GoToolContext,
        arguments: [String]
    ) throws -> [String] {
        let paths: [String]
        if arguments[0] == "." {
            guard let modulePath = findModule(context) else {
                throw GoToolError.invalidModule(
                    "go: cannot find main module; see 'go help modules'")
            }
            guard let entries = context.listDirectory(".") else {
                throw GoToolError.invalidModule("go: cannot read current directory")
            }
            try validateModule(context, path: modulePath)
            paths =
                entries
                .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") && !$0.hasSuffix("/") }
                .sorted()
        } else {
            paths = Array(arguments.prefix { $0.hasSuffix(".go") })
        }
        guard !paths.isEmpty else {
            throw GoToolError.noGoFiles(directory: context.currentDirectory)
        }
        return paths
    }

    private static func parseBuildOptions(
        _ context: any GoToolContext,
        arguments: [String]
    ) throws -> BuildOptions {
        var output: String?
        var inputs: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-o" {
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw GoToolError.invalidBuildArguments(
                        "go: flag needs an argument: -o")
                }
                output = arguments[index]
            } else if argument.hasPrefix("-o=") {
                let value = String(argument.dropFirst(3))
                guard !value.isEmpty else {
                    throw GoToolError.invalidBuildArguments(
                        "go: flag needs an argument: -o")
                }
                output = value
            } else if argument.hasPrefix("-") {
                throw GoToolError.invalidBuildArguments(
                    "go: unsupported build flag \(argument)")
            } else {
                inputs.append(argument)
            }
            index += 1
        }
        if inputs.isEmpty { inputs = ["."] }
        guard inputs == ["."] || inputs.allSatisfy({ $0.hasSuffix(".go") }) else {
            throw GoToolError.invalidBuildArguments(
                "go: unsupported build target \(inputs.joined(separator: " "))")
        }
        let outputPath = output ?? defaultBuildOutput(context, inputs: inputs)
        return BuildOptions(output: outputPath, inputs: inputs)
    }

    private static func parseInstallInputs(_ arguments: [String]) throws -> [String] {
        let inputs = arguments.isEmpty ? ["."] : arguments
        if let flag = inputs.first(where: { $0.hasPrefix("-") }) {
            throw GoToolError.invalidInstallArguments(
                "go: unsupported install flag \(flag)")
        }
        guard inputs == ["."] || inputs.allSatisfy({ $0.hasSuffix(".go") }) else {
            throw GoToolError.invalidInstallArguments(
                "go: unsupported install target \(inputs.joined(separator: " "))")
        }
        return inputs
    }

    private struct RunOptions {
        let inputs: [String]
        let arguments: [String]
    }

    /// Split `go run` build inputs from the argument vector passed to the guest.
    /// The supported build side remains deliberately small: either one package
    /// directory (`.`) or one or more explicit `.go` files.
    private static func parseRunOptions(_ arguments: [String]) throws -> RunOptions {
        guard let first = arguments.first else {
            return RunOptions(inputs: ["."], arguments: [])
        }
        if first == "." {
            return RunOptions(inputs: [first], arguments: Array(arguments.dropFirst()))
        }
        var inputCount = 0
        while inputCount < arguments.count, arguments[inputCount].hasSuffix(".go") {
            inputCount += 1
        }
        guard inputCount > 0 else {
            throw GoToolError.invalidBuildArguments(
                "go: unsupported run target \(first)")
        }
        return RunOptions(
            inputs: Array(arguments.prefix(inputCount)),
            arguments: Array(arguments.dropFirst(inputCount)))
    }

    private static func defaultBuildOutput(
        _ context: any GoToolContext,
        inputs: [String]
    ) -> String {
        if inputs == ["."] {
            return context.currentDirectory.split(separator: "/").last.map(String.init) ?? "main"
        }
        let filename = inputs[0].split(separator: "/").last.map(String.init) ?? "main.go"
        return filename.hasSuffix(".go") ? String(filename.dropLast(3)) : filename
    }

    private static func writeExecutable(
        _ context: any GoToolContext,
        executable: GoExecutable,
        output: String,
        operation: String
    ) throws {
        let image = try GoExecutableImage.encode(executable)
        if context.stat(output)?.isDirectory == true {
            throw GoToolError.executableOutput(
                "go: \(operation) output \"\(output)\" already exists and is a directory")
        }
        let descriptor = try context.openFile(
            output,
            flags: [.create, .truncate],
            access: .writeOnly)
        defer { try? context.closeFile(descriptor) }
        guard try context.writeFile(descriptor, image) == image.count else {
            throw GoToolError.executableOutput(
                "go: writing output \(output): short write")
        }
        let executableMode: FileMode = [
            .ownerRead, .ownerWrite, .ownerExecute,
            .groupRead, .groupExecute,
            .otherRead, .otherExecute,
        ]
        guard context.chmod(output, mode: executableMode) else {
            throw GoToolError.executableOutput(
                "go: setting executable mode on \(output) failed")
        }
    }

    private static func readFile(
        _ context: any GoToolContext,
        path: String,
        maximumBytes: Int
    ) throws -> [UInt8] {
        let descriptor = try context.openFile(path, access: .readOnly)
        defer { try? context.closeFile(descriptor) }
        let bytes = try context.readFile(descriptor, max: maximumBytes + 1)
        guard bytes.count <= maximumBytes else { throw GoToolError.sourceTooLarge(path) }
        return bytes
    }

    private static let maximumSourceBytes = 1_048_576

    private static let environmentOrder = [
        "GOHOSTOS", "GOHOSTARCH", "GOOS", "GOARCH", "GOVERSION", "GOMOD", "GOWORK", "GOPATH", "GOBIN",
        "GOCACHE", "GOMODCACHE", "GOPROXY", "GONOSUMDB", "GOPRIVATE", "GOROOT",
    ]

    private static func environment(_ context: any GoToolContext) -> [String: String] {
        let home = context.getenv("HOME") ?? "/home/user"
        let goPath = context.getenv("GOPATH") ?? join(home, "go")
        return [
            "GOHOSTOS": context.hostOperatingSystem,
            "GOHOSTARCH": context.hostArchitecture,
            "GOOS": GoExecutableImage.targetOS,
            "GOARCH": GoExecutableImage.targetArchitecture,
            "GOVERSION": toolVersion,
            "GOMOD": findModule(context) ?? "/dev/null",
            "GOWORK": "off",
            "GOPATH": goPath,
            "GOBIN": context.getenv("GOBIN") ?? join(goPath, "bin"),
            "GOCACHE": context.getenv("GOCACHE") ?? join(home, ".cache/go-build"),
            "GOMODCACHE": context.getenv("GOMODCACHE") ?? join(goPath, "pkg/mod"),
            "GOPROXY": context.getenv("GOPROXY") ?? "https://proxy.golang.org,direct",
            "GONOSUMDB": context.getenv("GONOSUMDB") ?? "",
            "GOPRIVATE": context.getenv("GOPRIVATE") ?? "",
            "GOROOT": "/usr/local/go",
        ]
    }

    private static func buildCacheRoot(_ context: any GoToolContext) throws -> String? {
        let value = environment(context)["GOCACHE"] ?? "/home/user/.cache/go-build"
        if value == "off" { return nil }
        guard value.hasPrefix("/") else {
            throw GoToolError.invalidCache(
                "go: GOCACHE must be an absolute path or 'off'")
        }
        return value
    }

    /// Root of the module cache (`GOMODCACHE`), where installed module sources
    /// live. Everything under it is ordinary VFS content, so a module is
    /// distributed like any other package: a `.pkg` archive that ships
    /// `<GOMODCACHE>/<module path>/*.go`.
    private static func moduleCacheRoot(_ context: any GoToolContext) -> String {
        environment(context)["GOMODCACHE"] ?? "/home/user/go/pkg/mod"
    }

    /// Directory holding the sources of `importPath`, or `nil` when the module is
    /// not present in the cache.
    ///
    /// The longest matching module prefix wins, mirroring Go's own resolution:
    /// importing `example.com/greet/text` finds the module `example.com/greet`
    /// and descends into its `text` package.
    private static func moduleCacheDirectory(
        _ context: any GoToolContext,
        importPath: String
    ) -> String? {
        let root = moduleCacheRoot(context)
        guard root.hasPrefix("/") else { return nil }
        var components = importPath.split(separator: "/").map(String.init)
        var suffix: [String] = []
        while !components.isEmpty {
            let candidate = join(root, components.joined(separator: "/"))
            if let status = context.stat(candidate), status.isDirectory {
                if suffix.isEmpty { return candidate }
                let directory = join(candidate, suffix.joined(separator: "/"))
                guard let nested = context.stat(directory), nested.isDirectory else { return nil }
                return directory
            }
            suffix.insert(components.removeLast(), at: 0)
        }
        return nil
    }

    private static func findModule(_ context: any GoToolContext) -> String? {
        var directory = context.currentDirectory
        while true {
            let candidate = join(directory, "go.mod")
            if context.stat(candidate) != nil { return candidate }
            if directory == "/" { return nil }
            directory = parent(of: directory)
        }
    }

    private static func validateModule(_ context: any GoToolContext, path: String) throws {
        let bytes = try readFile(context, path: path, maximumBytes: 1_048_576)
        let text = String(decoding: bytes, as: UTF8.self)
        var hasModuleDirective = false
        var languageDirective: String?
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let directive = fields.first, !directive.hasPrefix("//") else { continue }
            if directive == "module" { hasModuleDirective = fields.count >= 2 }
            if directive == "go", fields.count >= 2 { languageDirective = String(fields[1]) }
        }
        guard hasModuleDirective else {
            throw GoToolError.invalidModule(
                "go: errors parsing \(path): missing module declaration")
        }
        if let languageDirective {
            let components = languageDirective.split(separator: ".")
            guard components.count == 2 || components.count == 3,
                let major = Int(components[0]),
                let minor = Int(components[1]),
                components.dropFirst(2).allSatisfy({ Int($0) != nil }),
                major == 1
            else {
                throw GoToolError.invalidModule(
                    "go: errors parsing \(path): invalid go version '\(languageDirective)'")
            }
            guard minor <= 24 else {
                throw GoToolError.invalidModule(
                    "go: \(path) requires go >= \(languageDirective) (running go \(languageVersion))")
            }
        }
    }

    private static func join(_ directory: String, _ component: String) -> String {
        directory == "/" ? "/" + component : directory + "/" + component
    }

    private static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        var components = path.split(separator: "/")
        if !components.isEmpty { components.removeLast() }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func fail(_ context: any GoToolContext, _ message: String, status: Int32) {
        writeError(context, message.hasSuffix("\n") ? message : message + "\n")
        context.exit(status)
    }

    private static func writeError(_ context: any GoToolContext, _ text: String) {
        _ = context.write(2, Array(text.utf8))
    }

    private static let usage = """
        Go is a tool for managing Swiftix Go source code.

        Usage:

            go <command> [arguments]

        The commands available in this checkpoint are:

            build       compile packages and dependencies
            clean       remove object files and cached files
            env         print Swiftix Go environment information
            fmt         gofmt (reformat) package sources
            install     compile and install packages and dependencies
            mod init    initialize a new module in the current directory
            run         compile and run a main package
            test        run package tests
            version     print Swiftix Go version

        Use "go help" for this message.
        """ + "\n"

    private static let gofmtUsage = "usage: gofmt [-d] [-l] [-r rule] [-s] [-w] [path ...]\n"
}

private enum GoToolError: Error, CustomStringConvertible {
    case noGoFilesListed
    case noGoFiles(directory: String)
    case sourceTooLarge(String)
    case invalidModule(String)
    case invalidBuildArguments(String)
    case invalidCache(String)
    case invalidInstallArguments(String)
    case invalidFormatArguments(String)
    case executableOutput(String)

    var description: String {
        switch self {
        case .noGoFilesListed: return "go: no go files listed"
        case .noGoFiles(let directory): return "package .: no Go files in \(directory)"
        case .sourceTooLarge(let path): return "go: \(path): source file exceeds 1 MiB"
        case .invalidModule(let message): return message
        case .invalidBuildArguments(let message): return message
        case .invalidCache(let message): return message
        case .invalidInstallArguments(let message): return message
        case .invalidFormatArguments(let message): return message
        case .executableOutput(let message): return message
        }
    }
}

private struct BuildOptions {
    let output: String
    let inputs: [String]
}

private struct PackageNode {
    let path: String
    let directory: String
    let sources: [GoSourceFile]
    let imports: [String]
}

private struct PackageGraph {
    let moduleName: String
    let rootPath: String
    let packages: [String: PackageNode]
    /// Dependency-first order ending with the requested root package.
    let order: [String]
}

private struct FormatSelection {
    let paths: [String]
    let reportPackages: Bool
}

private struct GofmtOptions {
    let write: Bool
    let diff: Bool
    let list: Bool
    let showHelp: Bool
    let simplify: Bool
    let rewriteRule: String?
    let paths: [String]
}

private struct FormattedFile {
    let path: String
    let original: String
    let formatted: String
    let changed: Bool
}
