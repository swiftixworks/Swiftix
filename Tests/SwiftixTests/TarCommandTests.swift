import Testing
@testable import Swiftix

/// `tar` (ustar create / list / extract), the gzip container + inflate decoder
/// behind `-z`, and the `gzip` / `gunzip` / `zcat` commands. Archives are built
/// and unpacked through a real shell; the byte layout is checked at the ustar
/// field offsets, and reading is checked against archives and gzip streams
/// produced by the real tools (embedded as hex fixtures).
@Suite("tar + gzip")
struct TarCommandTests {

    // MARK: - Byte layout

    @Test func archiveHeaderFieldsAreUstar() {
        let shell = Shell()
        shell.seed { ctx in
            ctx.mkdir("/w")
            Self.put(ctx, "/w/a.txt", "hello\n", mode: 0o644, mtime: 1234)
        }
        shell.run("cd /w")
        #expect(shell.capture("tar cf /a.tar a.txt").status == 0)
        let archive = shell.bytes(of: "/a.tar") ?? []
        // One header block + one data block + two end blocks, padded to a
        // whole 20-block record.
        #expect(archive.count == 10240)
        guard archive.count == 10240 else { return }

        func field(_ offset: Int, _ length: Int) -> [UInt8] { Array(archive[offset..<(offset + length)]) }
        func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
        #expect(field(0, 6) == ascii("a.txt\0"))
        #expect(field(5, 95).allSatisfy { $0 == 0 })
        #expect(field(100, 8) == ascii("0000644\0"))
        #expect(field(108, 8) == ascii("0000000\0"))
        #expect(field(116, 8) == ascii("0000000\0"))
        #expect(field(124, 12) == ascii("00000000006\0"))
        #expect(field(136, 12) == ascii("00000002322\0"))       // 1234 in octal
        #expect(archive[156] == UInt8(ascii: "0"))
        #expect(field(157, 100).allSatisfy { $0 == 0 })
        #expect(field(257, 8) == ascii("ustar\u{0}00"))
        #expect(field(329, 16) == ascii("0000000\u{0}0000000\u{0}"))
        #expect(field(345, 167).allSatisfy { $0 == 0 })

        // Checksum: the byte sum with the field itself read as spaces, stored
        // as six octal digits, NUL, space.
        var sum = 0
        for index in 0..<512 { sum += (148..<156).contains(index) ? 0x20 : Int(archive[index]) }
        var digits = String(sum, radix: 8)
        while digits.count < 6 { digits = "0" + digits }
        #expect(field(148, 8) == ascii(digits + "\0 "))

        #expect(field(512, 6) == ascii("hello\n"))
        #expect(archive[518...].allSatisfy { $0 == 0 })
    }

    @Test func directoriesAndSymlinksUseTheirTypeFlags() {
        let shell = Shell()
        shell.seed { ctx in
            ctx.mkdir("/w/d")
            _ = ctx.chmod("/w/d", mode: FileMode(rawValue: 0o750))
            ctx.symlink("d/target", at: "/w/l")
        }
        shell.run("cd /w")
        _ = shell.capture("tar cf /a.tar d l")
        let archive = shell.bytes(of: "/a.tar") ?? []
        #expect(archive.count == 10240)
        guard archive.count == 10240 else { return }
        // Directory: trailing slash, type 5, no data blocks.
        #expect(Array(archive[0..<3]) == Array("d/\0".utf8))
        #expect(Array(archive[100..<108]) == Array("0000750\0".utf8))
        #expect(Array(archive[124..<136]) == Array("00000000000\0".utf8))
        #expect(archive[156] == UInt8(ascii: "5"))
        // Symlink: type 2 with the target in linkname, immediately after.
        #expect(Array(archive[512..<514]) == Array("l\0".utf8))
        #expect(archive[512 + 156] == UInt8(ascii: "2"))
        #expect(Array(archive[(512 + 157)..<(512 + 166)]) == Array("d/target\0".utf8))
        #expect(archive[1024...].allSatisfy { $0 == 0 })
    }

    @Test func longNamesUseThePrefixField() {
        let directory = String(repeating: "d", count: 60) + "/" + String(repeating: "e", count: 60)
        let name = directory + "/" + String(repeating: "f", count: 40) + ".txt"
        #expect(name.utf8.count > 100)
        let shell = Shell()
        shell.seed { ctx in
            ctx.mkdir("/w/" + directory)
            Self.put(ctx, "/w/" + name, "deep\n")
        }
        shell.run("cd /w")
        #expect(shell.capture("tar cf /a.tar \(name)").status == 0)
        let archive = shell.bytes(of: "/a.tar") ?? []
        guard archive.count == 10240 else {
            Issue.record("unexpected archive size \(archive.count)")
            return
        }
        // Split at the last slash: prefix = the directories, name = the file.
        #expect(String(decoding: archive[0..<44], as: UTF8.self) == String(repeating: "f", count: 40) + ".txt")
        #expect(archive[44] == 0)
        #expect(String(decoding: archive[345..<(345 + 121)], as: UTF8.self) == directory)
        #expect(archive[345 + 121] == 0)
        #expect(shell.capture("tar tf /a.tar").out == name + "\n")
        shell.run("mkdir /dst")
        #expect(shell.capture("tar xf /a.tar -C /dst").status == 0)
        #expect(shell.text(of: "/dst/" + name) == "deep\n")
    }

    @Test func namesFittingNoUstarFieldFallBackToGnuLongNameRecords() throws {
        // A single 150-character component cannot be split at a slash.
        var member = TarArchive.Member(name: String(repeating: "n", count: 150))
        member.size = 3
        member.linkName = ""
        let header = TarArchive.header(for: member)
        #expect(header.count == 3 * 512)
        #expect(String(decoding: header[0..<13], as: UTF8.self) == "././@LongLink")
        #expect(header[156] == UInt8(ascii: "L"))
        let archive = header + TarArchive.padded(Array("abc".utf8))
        let parsed = try TarArchive.members(of: archive + TarArchive.trailer(after: archive.count))
        #expect(parsed.count == 1)
        #expect(parsed.first?.name == member.name)
        #expect(parsed.first?.size == 3)
        #expect(parsed.first?.dataOffset == 3 * 512)

        // A long symlink target uses a K record the same way.
        var link = TarArchive.Member(name: "short")
        link.type = UInt8(ascii: "2")
        link.linkName = String(repeating: "t", count: 130)
        let linkArchive = TarArchive.header(for: link)
        let parsedLink = try TarArchive.members(of: linkArchive + TarArchive.trailer(after: linkArchive.count))
        #expect(parsedLink.first?.linkName == link.linkName)
        #expect(parsedLink.first?.name == "short")
    }

    @Test func nameSplitPrefersTheLongestPrefix() {
        #expect(TarArchive.splitName(Array("short/name".utf8))?.prefix.isEmpty == true)
        let name = Array((String(repeating: "a", count: 80) + "/" + String(repeating: "b", count: 50)
                            + "/" + String(repeating: "c", count: 20)).utf8)
        let split = TarArchive.splitName(name)
        #expect(split?.prefix.count == 131)
        #expect(split?.name.count == 20)
        #expect(TarArchive.splitName([UInt8](repeating: 0x78, count: 101)) == nil)
    }

    @Test func trailerPadsToAWholeRecord() {
        #expect(TarArchive.trailer(after: 0).count == 10240)
        #expect(TarArchive.trailer(after: 1024).count == 9216)
        #expect(TarArchive.trailer(after: 9216).count == 1024)
        #expect(TarArchive.trailer(after: 9728).count == 512 + 10240)
    }

    // MARK: - Round trip

    /// A small tree with every supported node type, distinct modes and mtimes.
    private static func seedProject(_ ctx: ProcessContext) {
        ctx.mkdir("/src/proj/sub")
        put(ctx, "/src/proj/a.txt", "alpha\n", mode: 0o640, mtime: 100)
        put(ctx, "/src/proj/sub/run.sh", "#!/bin/sh\necho run\n", mode: 0o755, mtime: 200)
        put(ctx, "/src/proj/empty", "", mode: 0o600, mtime: 300)
        ctx.symlink("a.txt", at: "/src/proj/link")
        _ = ctx.chmod("/src/proj/sub", mode: FileMode(rawValue: 0o700))
        ctx.utimes("/src/proj/sub", atime: 400, mtime: 400)
        ctx.utimes("/src/proj", atime: 500, mtime: 500)
    }

    @Test func createListExtractRoundTrip() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        var result = shell.capture("tar cf /t.tar proj")
        #expect(result.out == "")
        #expect(result.err == "")
        #expect(result.status == 0)

        result = shell.capture("tar tf /t.tar")
        #expect(result.out == "proj/\nproj/a.txt\nproj/empty\nproj/link\nproj/sub/\nproj/sub/run.sh\n")

        shell.run("mkdir /dst")
        result = shell.capture("tar xf /t.tar -C /dst")
        #expect(result.err == "")
        #expect(result.status == 0)
        #expect(shell.text(of: "/dst/proj/a.txt") == "alpha\n")
        #expect(shell.text(of: "/dst/proj/sub/run.sh") == "#!/bin/sh\necho run\n")
        #expect(shell.bytes(of: "/dst/proj/empty") == [])

        shell.probe { ctx in
            #expect(ctx.lstat("/dst/proj/a.txt")?.mode.rawValue == 0o640)
            #expect(ctx.lstat("/dst/proj/a.txt")?.mtime == 100)
            #expect(ctx.lstat("/dst/proj/sub/run.sh")?.mode.rawValue == 0o755)
            #expect(ctx.lstat("/dst/proj/sub/run.sh")?.mtime == 200)
            #expect(ctx.lstat("/dst/proj/empty")?.mode.rawValue == 0o600)
            #expect(ctx.lstat("/dst/proj/empty")?.mtime == 300)
            #expect(ctx.lstat("/dst/proj/link")?.type == .symlink)
            #expect(ctx.readlink("/dst/proj/link") == "a.txt")
            #expect(ctx.lstat("/dst/proj/sub")?.type == .directory)
            #expect(ctx.lstat("/dst/proj/sub")?.mode.rawValue == 0o700)
            // Directory times survive the extraction of their children.
            #expect(ctx.lstat("/dst/proj/sub")?.mtime == 400)
            #expect(ctx.lstat("/dst/proj")?.mtime == 500)
        }
        // The symlink resolves inside the extracted tree.
        #expect(shell.capture("cat /dst/proj/link").out == "alpha\n")
    }

    @Test func extractingTwiceReplacesFiles() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        shell.run("tar cf /t.tar proj")
        shell.run("mkdir /dst")
        shell.run("tar xf /t.tar -C /dst")
        shell.write("/dst/proj/a.txt", "locally modified, and longer\n")
        var result = shell.capture("tar xf /t.tar -C /dst")
        #expect(result.err == "")
        #expect(result.status == 0)
        #expect(shell.text(of: "/dst/proj/a.txt") == "alpha\n")

        // -k refuses to replace what is already there.
        shell.write("/dst/proj/a.txt", "keep me\n")
        result = shell.capture("tar xkf /t.tar -C /dst proj/a.txt")
        #expect(result.err == """
            tar: proj/a.txt: Cannot open: File exists
            tar: Exiting with failure status due to previous errors

            """)
        #expect(result.status == 2)
        #expect(shell.text(of: "/dst/proj/a.txt") == "keep me\n")
    }

    @Test func hardLinksAreStoredAsIndependentFiles() {
        let shell = Shell()
        shell.seed { ctx in
            ctx.mkdir("/w")
            Self.put(ctx, "/w/one", "shared\n")
            ctx.link("/w/one", at: "/w/two")
        }
        shell.run("cd /w")
        #expect(shell.capture("tar cf /a.tar one two").status == 0)
        #expect(shell.capture("tar tvf /a.tar").out == """
            -rw-r--r-- root/root         7 1970-01-01 00:00 one
            -rw-r--r-- root/root         7 1970-01-01 00:00 two

            """)
    }

    // MARK: - Flag styles and verbose output

    @Test func oldStyleAndDashedFlagBundles() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        let names = "proj/\nproj/a.txt\nproj/empty\nproj/link\nproj/sub/\nproj/sub/run.sh\n"
        #expect(shell.capture("tar cvf /one.tar proj").out == names)
        #expect(shell.capture("tar -cvf /two.tar proj").out == names)
        #expect(shell.capture("tar -c -v -f /three.tar proj").out == names)
        #expect(shell.capture("tar --create --verbose --file=/four.tar proj").out == names)
        let reference = shell.bytes(of: "/one.tar")
        #expect(reference?.count == 10240)
        #expect(shell.bytes(of: "/two.tar") == reference)
        #expect(shell.bytes(of: "/three.tar") == reference)
        #expect(shell.bytes(of: "/four.tar") == reference)

        #expect(shell.capture("tar tf /one.tar").out == names)
        #expect(shell.capture("tar -tf /one.tar").out == names)
        #expect(shell.capture("tar -t -f /one.tar").out == names)
        shell.run("mkdir /dst")
        shell.run("cd /dst")
        #expect(shell.capture("tar -xvf /one.tar").out == names)
        #expect(shell.text(of: "/dst/proj/a.txt") == "alpha\n")
    }

    @Test func verboseListingIsLongForm() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        shell.run("tar cf /t.tar proj")
        let expected = """
            drwxr-xr-x root/root         0 1970-01-01 00:08 proj/
            -rw-r----- root/root         6 1970-01-01 00:01 proj/a.txt
            -rw------- root/root         0 1970-01-01 00:05 proj/empty
            lrwxrwxrwx root/root         0 1970-01-01 00:00 proj/link -> a.txt
            drwx------ root/root         0 1970-01-01 00:06 proj/sub/
            -rwxr-xr-x root/root        19 1970-01-01 00:03 proj/sub/run.sh

            """
        #expect(shell.capture("tar tvf /t.tar").out == expected)
        #expect(shell.capture("tar -tvf /t.tar").out == expected)
    }

    @Test func ownerNamesComeFromThePasswordDatabase() {
        let shell = Shell()
        shell.seed { ctx in
            ctx.mkdir("/etc")
            Self.put(ctx, "/etc/passwd", "root:x:0:0:root:/root:/bin/sh\n")
            Self.put(ctx, "/etc/group", "wheel:x:0:\n")
            Self.put(ctx, "/f", "x", mtime: 9)
        }
        shell.run("tar cf /a.tar -C / f")
        let archive = shell.bytes(of: "/a.tar") ?? []
        guard archive.count == 10240 else { return }
        #expect(Array(archive[265..<270]) == Array("root\0".utf8))
        #expect(Array(archive[297..<303]) == Array("wheel\0".utf8))
        #expect(shell.capture("tar tvf /a.tar").out == "-rw-r--r-- root/wheel        1 1970-01-01 00:00 f\n")
    }

    // MARK: - -C, member selection, stdin/stdout

    @Test func changeDirectoryAppliesToFollowingOperands() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        #expect(shell.capture("tar cf /t.tar -C /src/proj a.txt -C sub run.sh").status == 0)
        #expect(shell.capture("tar tf /t.tar").out == "a.txt\nrun.sh\n")
        let result = shell.capture("tar cf /t2.tar -C /nowhere a.txt")
        #expect(result.err == "tar: /nowhere: Cannot open: No such file or directory\n"
                + "tar: Error is not recoverable: exiting now\n")
        #expect(result.status == 2)
    }

    @Test func memberOperandsSelectByNameDirectoryAndWildcard() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        shell.run("tar cf /t.tar proj")
        #expect(shell.capture("tar tf /t.tar proj/a.txt").out == "proj/a.txt\n")
        #expect(shell.capture("tar tf /t.tar proj/sub").out == "proj/sub/\nproj/sub/run.sh\n")
        #expect(shell.capture("tar tf /t.tar 'proj/*.txt'").out == "proj/a.txt\n")
        #expect(shell.capture("tar tf /t.tar '*.sh' proj/empty").out == "proj/empty\nproj/sub/run.sh\n")

        shell.run("mkdir /dst")
        #expect(shell.capture("tar xf /t.tar -C /dst proj/sub").status == 0)
        #expect(shell.text(of: "/dst/proj/sub/run.sh") == "#!/bin/sh\necho run\n")
        #expect(shell.bytes(of: "/dst/proj/a.txt") == nil)

        let result = shell.capture("tar tf /t.tar proj/a.txt nothere")
        #expect(result.out == "proj/a.txt\n")
        #expect(result.err == """
            tar: nothere: Not found in archive
            tar: Exiting with failure status due to previous errors

            """)
        #expect(result.status == 2)
    }

    @Test func dashArchiveMeansStandardStreams() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        #expect(shell.capture("tar cf - proj | tar tf -").out
                == "proj/\nproj/a.txt\nproj/empty\nproj/link\nproj/sub/\nproj/sub/run.sh\n")
        shell.run("mkdir /dst")
        #expect(shell.capture("tar cf - -C /src/proj a.txt sub | tar xf - -C /dst").status == 0)
        #expect(shell.text(of: "/dst/a.txt") == "alpha\n")
        #expect(shell.text(of: "/dst/sub/run.sh") == "#!/bin/sh\necho run\n")
        // With the archive on stdout, -v names go to stderr.
        let result = shell.capture("tar cvf - proj/a.txt")
        #expect(result.err == "proj/a.txt\n")
        #expect(result.out.utf8.count == 10240)
        // Redirected stdin works like a pipe.
        shell.run("tar cf /t.tar proj/a.txt")
        #expect(shell.capture("tar t < /t.tar").out == "proj/a.txt\n")
    }

    @Test func extractToStandardOutput() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        shell.run("tar cf /t.tar proj")
        #expect(shell.capture("tar xOf /t.tar proj/a.txt").out == "alpha\n")
    }

    @Test func leadingSlashIsStripped() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        let result = shell.capture("tar cf /t.tar /src/proj/a.txt /src/proj/empty")
        #expect(result.err == "tar: Removing leading '/' from member names\n")
        #expect(result.status == 0)
        #expect(shell.capture("tar tf /t.tar").out == "src/proj/a.txt\nsrc/proj/empty\n")
    }

    @Test func excludeAndStripComponents() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        #expect(shell.capture("tar cf /t.tar --exclude='*.txt' --exclude=sub proj").status == 0)
        #expect(shell.capture("tar tf /t.tar").out == "proj/\nproj/empty\nproj/link\n")

        shell.run("tar cf /full.tar proj")
        #expect(shell.capture("tar tf /full.tar --exclude=proj/sub").out
                == "proj/\nproj/a.txt\nproj/empty\nproj/link\n")
        shell.run("mkdir /dst")
        #expect(shell.capture("tar xf /full.tar -C /dst --strip-components=1").status == 0)
        #expect(shell.text(of: "/dst/a.txt") == "alpha\n")
        #expect(shell.text(of: "/dst/sub/run.sh") == "#!/bin/sh\necho run\n")
        shell.run("mkdir /dst2")
        #expect(shell.capture("tar xf /full.tar -C /dst2 --strip-components 2").status == 0)
        #expect(shell.text(of: "/dst2/run.sh") == "#!/bin/sh\necho run\n")
        #expect(shell.bytes(of: "/dst2/a.txt") == nil)
    }

    @Test func theArchiveIsNotAddedToItself() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src/proj")
        let result = shell.capture("tar cf out.tar .")
        #expect(result.err == "tar: ./out.tar: file is the archive; not dumped\n")
        #expect(result.status == 0)
        #expect(shell.capture("tar tf out.tar").out == "./\n./a.txt\n./empty\n./link\n./sub/\n./sub/run.sh\n")
    }

    // MARK: - Errors

    @Test func missingArchive() {
        let shell = Shell()
        for command in ["tar xf /a.tar", "tar tf /a.tar"] {
            let result = shell.capture(command)
            #expect(result.err == "tar: /a.tar: Cannot open: No such file or directory\n"
                    + "tar: Error is not recoverable: exiting now\n")
            #expect(result.status == 2)
        }
    }

    @Test func notAnArchive() {
        let shell = Shell()
        shell.write("/junk", [UInt8](repeating: 0x41, count: 2048))
        var result = shell.capture("tar tf /junk")
        #expect(result.err == "tar: This does not look like a tar archive\n"
                + "tar: Exiting with failure status due to previous errors\n")
        #expect(result.status == 2)
        shell.write("/tiny", "short")
        result = shell.capture("tar xf /tiny")
        #expect(result.status == 2)
    }

    @Test func corruptedChecksumIsRejected() {
        let shell = Shell()
        shell.write("/f", "data")
        shell.run("tar cf /a.tar -C / f")
        var archive = shell.bytes(of: "/a.tar") ?? []
        guard archive.count == 10240 else { return }
        archive[0] = UInt8(ascii: "g")            // rename without fixing the checksum
        shell.write("/bad.tar", archive)
        #expect(shell.capture("tar tf /bad.tar").status == 2)
    }

    @Test func truncatedArchive() {
        let shell = Shell()
        shell.write("/f", [UInt8](repeating: 0x42, count: 3000))
        shell.run("tar cf /a.tar -C / f")
        let archive = shell.bytes(of: "/a.tar") ?? []
        shell.write("/cut.tar", Array(archive.prefix(1024)))
        let result = shell.capture("tar tf /cut.tar")
        #expect(result.err == "tar: Unexpected EOF in archive\ntar: Error is not recoverable: exiting now\n")
        #expect(result.status == 2)
    }

    @Test func usageErrors() {
        let shell = Shell()
        var result = shell.capture("tar -f /a.tar")
        #expect(result.err == """
            tar: You must specify one of the '-Acdtrux', '--delete' or '--test-label' options
            Try 'tar --help' or 'tar --usage' for more information.

            """)
        #expect(result.status == 2)
        result = shell.capture("tar cf /a.tar")
        #expect(result.err == """
            tar: Cowardly refusing to create an empty archive
            Try 'tar --help' or 'tar --usage' for more information.

            """)
        #expect(result.status == 2)
        result = shell.capture("tar -cQf /a.tar x")
        #expect(result.err == "tar: invalid option -- 'Q'\nTry 'tar --help' or 'tar --usage' for more information.\n")
        #expect(result.status == 2)
        result = shell.capture("tar --bogus")
        #expect(result.err.hasPrefix("tar: unrecognized option '--bogus'\n"))
        #expect(shell.capture("tar --help").out.hasPrefix("Usage: tar {c|x|t}[vzf]"))
    }

    @Test func missingInputFileIsReportedButTheRestIsArchived() {
        let shell = Shell()
        shell.write("/real", "content")
        let result = shell.capture("tar cf /a.tar -C / real ghost")
        #expect(result.err == """
            tar: ghost: Cannot stat: No such file or directory
            tar: Exiting with failure status due to previous errors

            """)
        #expect(result.status == 2)
        #expect(shell.capture("tar tf /a.tar").out == "real\n")
    }

    @Test func parentDirectoryReferencesAreNotExtracted() throws {
        var member = TarArchive.Member(name: "../escape")
        member.size = 4
        var archive = TarArchive.header(for: member) + TarArchive.padded(Array("evil".utf8))
        archive += TarArchive.trailer(after: archive.count)
        let shell = Shell()
        shell.write("/evil.tar", archive)
        shell.run("mkdir /dst")
        let result = shell.capture("tar xf /evil.tar -C /dst")
        #expect(result.err == """
            tar: ../escape: Member name contains '..'
            tar: Exiting with failure status due to previous errors

            """)
        #expect(result.status == 2)
        #expect(shell.bytes(of: "/escape") == nil)
    }

    // MARK: - Reading archives made by the real tools

    /// `tar --format ustar -czf` output from bsdtar: a directory tree with a
    /// 0640 file, a 0755 script, and a symlink, mtime 946684842, owner
    /// root/wheel, compressed by gzip with a dynamic-Huffman deflate block.
    private static let realTarball = """
        1f8b080006bfc56a0003ed95dd0a82301480bdf62916ddebd9afcf933198264ea6528fdf348832302aa684e7bb1963839d9d\
        efecac71b64ca3b0004026251946cf74bc4d2003ce99a04a320294514e232203c735d2b7ddc1f9509cb5dddcbeb3d1ba9a59\
        9f5eee4f6806ff6d9f87ac812ffc678ca1ff2518fd57457d0a78c6e7fe85122a22cce8aab249779915f323e8bf4c03e7d9e7\
        438917ef0ffe299bf8e799f2ef1fc284f3ccc6fd8fea894f41bc7624c81adcff7fd7d7496b829cf1b6ff333eedffa000dfff\
        12ec77695ed4696b627d3496f82ac046802008b205ae788c05f400120000
        """

    @Test func readsARealGzippedUstarArchive() {
        let shell = Shell()
        shell.write("/proj.tgz", Self.bytes(hex: Self.realTarball))
        let listing = """
            drwxr-xr-x root/wheel        0 2000-01-01 00:00 proj/
            drwxr-xr-x root/wheel        0 2000-01-01 00:00 proj/sub/
            lrwxr-xr-x root/wheel        0 2000-01-01 00:00 proj/link -> hello.txt
            -rw-r----- root/wheel       10 2000-01-01 00:00 proj/hello.txt
            -rwxr-xr-x root/wheel       19 2000-01-01 00:00 proj/sub/run.sh

            """
        // -z given, and auto-detected from the magic number without it.
        #expect(shell.capture("tar tzvf /proj.tgz").out == listing)
        #expect(shell.capture("tar tvf /proj.tgz").out == listing)
        #expect(shell.capture("tar tf /proj.tgz").out
                == "proj/\nproj/sub/\nproj/link\nproj/hello.txt\nproj/sub/run.sh\n")

        shell.run("mkdir /dst")
        let result = shell.capture("tar xzf /proj.tgz -C /dst")
        #expect(result.err == "")
        #expect(result.status == 0)
        #expect(shell.text(of: "/dst/proj/hello.txt") == "hello tar\n")
        #expect(shell.text(of: "/dst/proj/sub/run.sh") == "#!/bin/sh\necho run\n")
        shell.probe { ctx in
            #expect(ctx.readlink("/dst/proj/link") == "hello.txt")
            #expect(ctx.lstat("/dst/proj/hello.txt")?.mode.rawValue == 0o640)
            #expect(ctx.lstat("/dst/proj/sub/run.sh")?.mode.rawValue == 0o755)
            #expect(ctx.lstat("/dst/proj/hello.txt")?.mtime == 946_684_842)
            #expect(ctx.lstat("/dst/proj")?.mtime == 946_684_842)
        }
    }

    @Test func readsPaxAndOldStyleHeaders() throws {
        // A pax `x` record overriding the path of the member that follows.
        let record = "30 path=pax/long/override.txt\n"
        #expect(record.utf8.count == 30)
        var extended = TarArchive.Member(name: "PaxHeader/x")
        extended.type = UInt8(ascii: "x")
        extended.size = record.utf8.count
        var file = TarArchive.Member(name: "short.txt")
        file.size = 2
        var archive = TarArchive.header(for: extended) + TarArchive.padded(Array(record.utf8))
        archive += TarArchive.header(for: file) + TarArchive.padded(Array("hi".utf8))
        // An old V7 header: no magic, NUL type flag, space-terminated numbers.
        var old = [UInt8](repeating: 0, count: 512)
        func set(_ offset: Int, _ text: String) {
            for (index, byte) in text.utf8.enumerated() { old[offset + index] = byte }
        }
        set(0, "v7file")
        set(100, "   644 ")
        set(108, "     0 ")
        set(116, "     0 ")
        set(124, "          3 ")
        set(136, "         12 ")
        for index in 148..<156 { old[index] = 0x20 }
        let sum = old.reduce(0) { $0 + Int($1) }
        set(148, String(sum, radix: 8) + "\0")
        archive += old + TarArchive.padded(Array("old".utf8))
        archive += TarArchive.trailer(after: archive.count)

        let members = try TarArchive.members(of: archive)
        #expect(members.map(\.name) == ["pax/long/override.txt", "v7file"])
        #expect(members.last?.mode == 0o644)
        #expect(members.last?.size == 3)
        #expect(members.last?.mtime == 10)
        #expect(members.last?.type == UInt8(ascii: "0"))
    }

    // MARK: - gzip format

    private static let dickens = "It was the best of times, it was the worst of times, it was the age of "
        + "wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of "
        + "incredulity, it was the season of Light, it was the season of Darkness\n"

    /// `gzip -9` of `dickens`: one dynamic-Huffman block (BTYPE 2).
    private static let dynamicFixture = """
        1f8b080000000000021375cdc10980301044d1bb556c0196e145b089442766316625bb12ec5e721241cfef0f331a55a7\
        6411e4a14612c87887f6c48f54297fe45634a8ac8bec5f1244126bccd0f71087ccb1051e8911be8df35cb09c89ed7a05\
        0aa7925b31f11aedc70657b6f6dbdd8c607a47e5000000
        """

    @Test func inflatesADynamicHuffmanStream() throws {
        let compressed = Self.bytes(hex: Self.dynamicFixture)
        #expect((compressed[10] >> 1) & 3 == 2)          // BTYPE: dynamic Huffman
        #expect(compressed.count < Self.dickens.utf8.count)
        #expect(try Gzip.decompress(compressed) == Array(Self.dickens.utf8))
    }

    @Test func inflatesAFixedHuffmanStreamWithOverlappingCopies() throws {
        // `gzip -9` of "hello hello hello hello\n": a fixed block (BTYPE 1)
        // whose back-reference overlaps its own output.
        let compressed = Self.bytes(hex: "1f8b0800000000000213cb48cdc9c957c84027b9000088590b18000000")
        #expect((compressed[10] >> 1) & 3 == 1)
        #expect(try Gzip.decompress(compressed) == Array("hello hello hello hello\n".utf8))
    }

    @Test func skipsOptionalHeaderFields() throws {
        // Written by Python's gzip module with FNAME = "name.txt".
        let compressed = Self.bytes(hex:
            "1f8b08080100000002ff6e616d652e74787400cb4bcc4d4d51c84dcd4d4a2de20200e7d2f4ed0d000000")
        #expect(compressed[3] == 0x08)
        #expect(try Gzip.decompress(compressed) == Array("named member\n".utf8))
    }

    @Test func storedCompressionRoundTrips() throws {
        for size in [0, 1, 100, 65534, 65535, 65536, 65537, 200_000] {
            let data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 8)) }
            let compressed = Gzip.compressStored(data)
            #expect(Gzip.hasMagic(compressed))
            #expect(compressed[2] == 8)
            // Header (10) + one 5-byte block header per 65535 bytes + trailer (8).
            let blocks = Swift.max(1, (size + 65534) / 65535)
            #expect(compressed.count == 10 + size + 5 * blocks + 8)
            #expect(try Gzip.decompress(compressed) == data)
        }
    }

    @Test func storedStreamLayout() {
        #expect(Gzip.compressStored(Array("hi".utf8)) == [
            0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03,      // header
            0x01, 0x02, 0x00, 0xFD, 0xFF, 0x68, 0x69,            // final stored block
            0xAC, 0x2A, 0x93, 0xD8,                              // CRC-32 of "hi"
            0x02, 0x00, 0x00, 0x00,                              // ISIZE
        ])
    }

    @Test func crc32MatchesTheCheckValue() {
        #expect(Gzip.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(Gzip.crc32([]) == 0)
    }

    @Test func concatenatedMembersDecodeAsOneStream() throws {
        let joined = Gzip.compressStored(Array("first ".utf8)) + Self.bytes(hex: Self.dynamicFixture)
        #expect(try Gzip.decompress(joined) == Array(("first " + Self.dickens).utf8))
        // Trailing zero padding (tape blocking) is ignored.
        #expect(try Gzip.decompress(Gzip.compressStored([1, 2, 3]) + [0, 0, 0, 0]) == [1, 2, 3])
    }

    @Test func corruptStreamsAreRejected() {
        var compressed = Self.bytes(hex: Self.dynamicFixture)
        #expect(throws: Gzip.Failure.notGzip) { try Gzip.decompress(Array("plain text".utf8)) }
        #expect(throws: Gzip.Failure.unexpectedEnd) { try Gzip.decompress(Array(compressed.prefix(60))) }
        compressed[compressed.count - 6] ^= 0xFF          // CRC byte
        #expect(throws: Gzip.Failure.crcMismatch) { try Gzip.decompress(compressed) }
        var stored = Gzip.compressStored(Array("hello".utf8))
        stored[stored.count - 1] = 9                      // ISIZE
        #expect(throws: Gzip.Failure.lengthMismatch) { try Gzip.decompress(stored) }
        stored = Gzip.compressStored(Array("hello".utf8))
        stored[10] = 0x07                                 // reserved block type 3
        #expect(throws: Gzip.Failure.invalidData) { try Gzip.decompress(stored) }
    }

    // MARK: - tar -z

    @Test func gzippedArchiveRoundTrip() {
        let shell = Shell()
        shell.seed(Self.seedProject)
        shell.run("cd /src")
        #expect(shell.capture("tar czf /t.tgz proj").status == 0)
        let compressed = shell.bytes(of: "/t.tgz") ?? []
        #expect(Gzip.hasMagic(compressed))
        #expect((try? Gzip.decompress(compressed))?.count == 10240)

        let names = "proj/\nproj/a.txt\nproj/empty\nproj/link\nproj/sub/\nproj/sub/run.sh\n"
        #expect(shell.capture("tar tzf /t.tgz").out == names)
        #expect(shell.capture("tar tf /t.tgz").out == names)
        #expect(shell.capture("tar -ztf /t.tgz").out == names)
        shell.run("mkdir /dst")
        #expect(shell.capture("tar xzf /t.tgz -C /dst").status == 0)
        #expect(shell.text(of: "/dst/proj/sub/run.sh") == "#!/bin/sh\necho run\n")
        #expect(shell.capture("tar czf - proj | tar xzOf - proj/a.txt").out == "alpha\n")
    }

    @Test func gzipFlagOnAPlainArchiveFails() {
        let shell = Shell()
        shell.write("/f", "x")
        shell.run("tar cf /a.tar -C / f")
        let result = shell.capture("tar tzf /a.tar")
        #expect(result.err == """
            gzip: /a.tar: not in gzip format
            tar: Child returned status 1
            tar: Error is not recoverable: exiting now

            """)
        #expect(result.status == 2)
    }

    // MARK: - gzip / gunzip / zcat

    @Test func gzipReplacesTheFileAndGunzipRestoresIt() {
        let shell = Shell()
        shell.seed { ctx in Self.put(ctx, "/note.txt", "some text\n", mode: 0o600, mtime: 77) }
        var result = shell.capture("gzip /note.txt")
        #expect(result.err == "")
        #expect(result.status == 0)
        #expect(shell.bytes(of: "/note.txt") == nil)
        #expect(shell.bytes(of: "/note.txt.gz") == Gzip.compressStored(Array("some text\n".utf8)))
        shell.probe { ctx in
            #expect(ctx.stat("/note.txt.gz")?.mode.rawValue == 0o600)
            #expect(ctx.stat("/note.txt.gz")?.mtime == 77)
        }
        result = shell.capture("gunzip /note.txt.gz")
        #expect(result.status == 0)
        #expect(shell.bytes(of: "/note.txt.gz") == nil)
        #expect(shell.text(of: "/note.txt") == "some text\n")
        shell.probe { ctx in #expect(ctx.stat("/note.txt")?.mtime == 77) }
    }

    @Test func gzipKeepStdoutAndDecompressFlags() {
        let shell = Shell()
        shell.write("/a", "payload\n")
        #expect(shell.capture("gzip -k /a").status == 0)
        #expect(shell.text(of: "/a") == "payload\n")
        #expect(shell.capture("zcat /a.gz").out == "payload\n")
        #expect(shell.capture("gunzip -c /a.gz").out == "payload\n")
        #expect(shell.capture("gzip -dc /a.gz").out == "payload\n")
        #expect(shell.bytes(of: "/a.gz") != nil)
        #expect(shell.capture("gzip -c /a | gunzip").out == "payload\n")
        #expect(shell.capture("echo piped | gzip | zcat").out == "piped\n")
        #expect(shell.capture("gzip -t /a.gz").status == 0)
        // gzip -d on a .tgz yields a .tar.
        shell.run("tar czf /b.tgz -C / a")
        #expect(shell.capture("gzip -d /b.tgz").status == 0)
        #expect(shell.capture("tar tf /b.tar").out == "a\n")
    }

    @Test func zcatDecodesARealGzipFile() {
        let shell = Shell()
        shell.write("/real.gz", Self.bytes(hex: Self.dynamicFixture))
        #expect(shell.capture("zcat /real.gz").out == Self.dickens)
        #expect(shell.capture("gunzip /real.gz").status == 0)
        #expect(shell.text(of: "/real") == Self.dickens)
    }

    @Test func gzipErrors() {
        let shell = Shell()
        var result = shell.capture("gzip /missing")
        #expect(result.err == "gzip: /missing: No such file or directory\n")
        #expect(result.status == 1)

        shell.write("/plain.gz", "this is not compressed")
        result = shell.capture("gunzip /plain.gz")
        #expect(result.err == "gzip: /plain.gz: not in gzip format\n")
        #expect(result.status == 1)
        #expect(shell.text(of: "/plain.gz") == "this is not compressed")

        shell.write("/odd.dat", "x")
        result = shell.capture("gunzip /odd.dat")
        #expect(result.err == "gzip: /odd.dat: unknown suffix -- ignored\n")
        #expect(result.status == 2)

        shell.write("/a", "new")
        shell.write("/a.gz", "old")
        result = shell.capture("gzip /a")
        #expect(result.err == "gzip: /a.gz already exists; not overwritten\n")
        #expect(result.status == 2)
        #expect(shell.text(of: "/a.gz") == "old")
        #expect(shell.capture("gzip -f /a").status == 0)
        #expect(shell.bytes(of: "/a.gz") == Gzip.compressStored(Array("new".utf8)))

        result = shell.capture("gzip /a.gz")
        #expect(result.err == "gzip: /a.gz already has .gz suffix -- unchanged\n")
        shell.run("mkdir /d")
        result = shell.capture("gzip /d")
        #expect(result.err == "gzip: /d is a directory -- ignored\n")
        #expect(shell.capture("echo junk | gunzip").err == "gzip: stdin: not in gzip format\n")
    }

    // MARK: - Harness

    private static func put(_ ctx: ProcessContext, _ path: String, _ text: String,
                            mode: UInt16 = 0o644, mtime: Double = 0) {
        guard let fd = ctx.open(path, create: true, truncate: true) else { return }
        ctx.write(fd, Array(text.utf8))
        ctx.close(fd)
        _ = ctx.chmod(path, mode: FileMode(rawValue: mode))
        ctx.utimes(path, atime: mtime, mtime: mtime)
    }

    private static func bytes(hex: String) -> [UInt8] {
        let digits = hex.utf8.compactMap { byte -> UInt8? in
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        return stride(from: 0, to: digits.count - 1, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }

    /// Boots a kernel + pty + interactive shell (echo off), runs command lines,
    /// and reads the files they produce back out of the VFS.
    private final class Shell {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()

        init() {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak pty] in
                guard let pty else { return }
                _ = pty.readForApp(max: 65_535)
            }
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

        func run(_ line: String) {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }

        func capture(_ command: String) -> (out: String, err: String, status: Int32) {
            run("\(command) > /.out 2> /.err")
            run("echo $? > /.status")
            let status = Int32(text(of: "/.status").split(separator: "\n").first ?? "") ?? -1
            return (text(of: "/.out"), text(of: "/.err"), status)
        }

        /// Run `body` as a process (to build fixtures through the syscall surface).
        func seed(_ body: @escaping (ProcessContext) -> Void) {
            kernel.spawn("seed") { ctx in
                body(ctx)
                ctx.exit(0)
            }
            loop.runUntilIdle()
        }

        /// Run `body` as a process to inspect the resulting filesystem.
        func probe(_ body: @escaping (ProcessContext) -> Void) { seed(body) }

        func write(_ path: String, _ text: String) { write(path, Array(text.utf8)) }

        func write(_ path: String, _ bytes: [UInt8]) {
            seed { ctx in
                if let fd = ctx.open(path, create: true, truncate: true) {
                    ctx.write(fd, bytes)
                    ctx.close(fd)
                }
            }
        }

        func bytes(of path: String) -> [UInt8]? {
            final class Box { var bytes: [UInt8]? }
            let box = Box()
            seed { ctx in
                guard ctx.stat(path)?.type == .regular, let fd = ctx.open(path) else { return }
                var data: [UInt8] = []
                while true {
                    let chunk = ctx.read(fd, max: 1 << 16)
                    if chunk.isEmpty { break }
                    data.append(contentsOf: chunk)
                }
                box.bytes = data
                ctx.close(fd)
            }
            loop.runUntilIdle()
            return box.bytes
        }

        func text(of path: String) -> String {
            bytes(of: path).map { String(decoding: $0, as: UTF8.self) } ?? "<missing>"
        }
    }
}
