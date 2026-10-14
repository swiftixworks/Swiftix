/// The Go files of the run-time library, `Sources/SwiftixGoLibrary`, against
/// what the build reads of them.
///
/// The files are the source of truth and `Scripts/generate-go-library.py`
/// writes `SourceLibraryText.swift` from them. These tests fail when that
/// file is stale, and when a file breaks one of the rules the guide at the
/// top of `SourceLibrary.swift` gives: run the script, or mend the file.

import Foundation
@testable import SwiftixGo
import Testing

@Suite("Go source library files")
struct GoSourceLibraryFilesTests {
    /// The directory of the Go files, found from where this file is.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftixGoLibrary")

    /// The files of each package on disk, by its import path, in the order
    /// of their names.
    private func packagesOnDisk() throws -> [String: [GoSourceFile]] {
        let manager = FileManager.default
        var packages: [String: [GoSourceFile]] = [:]
        let enumerator = try #require(manager.enumerator(atPath: Self.root.path))
        var relative: [String] = []
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".go"), !path.hasSuffix("_test.go") { relative.append(path) }
        }
        for path in relative.sorted() {
            let package = (path as NSString).deletingLastPathComponent
            let text = try String(
                contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            packages[package, default: []].append(
                GoSourceFile(path: "$GOROOT/src/" + path, text: text))
        }
        return packages
    }

    /// `text` with each of `names` followed by `suffix` where it is a word
    /// of its own.
    private func suffixing(_ names: Set<String>, with suffix: String, in text: String) -> String {
        var result = ""
        var word = ""
        func flush() {
            result += names.contains(word) ? word + suffix : word
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    @Test func theGeneratedTextIsWhatTheGoFilesSay() throws {
        let onDisk = try packagesOnDisk()

        #expect(Set(onDisk.keys) == GoSourceLibraryText.paths)
        for (path, files) in onDisk {
            let generated = try #require(GoSourceLibraryText.files(ofPackage: path))
            #expect(generated.map(\.path) == files.map(\.path), "the files of \(path)")
            for (built, written) in zip(generated, files) {
                #expect(
                    built.text == written.text,
                    "\(written.path) changed: run Scripts/generate-go-library.py")
            }
        }
    }

    /// The table that says which names of a package are written in Go is
    /// made without parsing: it must be what the parser finds.
    @Test func theNamesTableIsWhatTheTextDeclares() throws {
        for path in GoSourceLibraryText.paths {
            var declared: Set<String> = []
            for source in try #require(GoSourceLibraryText.files(ofPackage: path)) {
                let file = try GoParser.parse(source)
                declared.formUnion(file.typeDeclarations.map(\.name))
                declared.formUnion(file.globalDeclarations.map(\.name))
                declared.formUnion(file.functions.lazy.filter { $0.receiver == nil }.map(\.name))
            }
            declared.remove("_")
            #expect(GoSourceLibraryText.declared[path] == declared, "the names of \(path)")
        }
    }

    /// `sort/zsortfunc.go` is `sort/sorting.go` for a slice with a `less`
    /// function, so that both families compare and exchange alike.
    @Test func theSliceFamilyIsDerivedFromTheInterfaceFamily() throws {
        let files = try #require(GoSourceLibraryText.files(ofPackage: "sort"))
        let sorting = try #require(files.first { $0.path.hasSuffix("/sorting.go") }).text
        let derived = try #require(files.first { $0.path.hasSuffix("/zsortfunc.go") }).text
        let names = Set(
            try GoParser.parse(GoSourceFile(path: "sorting.go", text: sorting)).functions.map(\.name))
        var body = String(sorting[try #require(sorting.range(of: "package sort\n")).upperBound...])
        body = suffixing(names, with: "Func", in: body)
        for (written, meant) in [
            ("data Interface", "x any, less func(i, j int) bool"), ("data.Less(", "less("),
            ("data.Swap(", "native.swap(x, "), ("(data, ", "(x, less, "),
        ] {
            body = body.replacingOccurrences(of: written, with: meant)
        }

        #expect(
            derived
                == "// Code generated by Scripts/generate-go-library.py from sorting.go; DO NOT EDIT.\n\n"
                + "package sort\n" + body)
    }

    /// What the guide asks of a file: its package is named by the last
    /// element of its path, which programs may import; it has no `init`
    /// function; and it is formatted.
    @Test func everyFileKeepsTheRules() throws {
        for path in GoSourceLibraryText.paths {
            #expect(GoStandardLibrary.supportedPackages.contains(path), "\(path) can be imported")
            for source in try #require(GoSourceLibraryText.files(ofPackage: path)) {
                let file = try GoParser.parse(source)
                #expect(file.packageName == GoImportName.defaultName(ofPath: path), "\(source.path)")
                #expect(!file.functions.contains { $0.name == "init" && $0.receiver == nil }, "\(source.path)")
                #expect(try GoFormatter.format(source) == source.text, "\(source.path) is not formatted")
            }
        }
    }

    /// Every `native.name(...)` of the text is a native the compiler knows
    /// and the linker leaves to the VM.
    @Test func everyNativeTheTextCallsIsDeclared() throws {
        for path in GoSourceLibraryText.paths {
            let package = GoImportName.defaultName(ofPath: path)
            for source in try #require(GoSourceLibraryText.files(ofPackage: path)) {
                var rest = source.text[...]
                while let found = rest.range(of: GoSourceLibrary.nativeQualifier + ".") {
                    let name = String(rest[found.upperBound...].prefix { $0.isLetter || $0.isNumber })
                    let before = rest[..<found.lowerBound].last
                    rest = rest[found.upperBound...]
                    if let before, before.isLetter || before.isNumber || before == "." { continue }
                    guard rest.dropFirst(name.count).first == "(" else { continue }
                    let native = GoStandardLibrary.nativeFunction(package: package, member: "$" + name)
                    #expect(native != nil, "native.\(name) of \(path)")
                    if let native {
                        #expect(native.symbol == "$\(package).\(name)")
                        #expect(GoStandardLibrary.isNativeCallName(native.symbol))
                    }
                }
            }
        }
    }
}
