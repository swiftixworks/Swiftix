import Testing
@testable import Swiftix

@Suite("Typed syscall error model")
struct SyscallErrorTests {

    /// Every case maps to its POSIX errno-style numeric code (design.md §2).
    @Test func codeMapsToErrnoValue() {
        #expect(SyscallError.noSuchFileOrDirectory.code == 2)   // ENOENT
        #expect(SyscallError.interrupted.code == 4)             // EINTR
        #expect(SyscallError.badFileDescriptor.code == 9)       // EBADF
        #expect(SyscallError.noChildProcess.code == 10)         // ECHILD
        #expect(SyscallError.wouldBlock.code == 11)             // EAGAIN
        #expect(SyscallError.fileExists.code == 17)             // EEXIST
        #expect(SyscallError.isADirectory.code == 21)           // EISDIR
        #expect(SyscallError.invalidArgument.code == 22)        // EINVAL
        #expect(SyscallError.brokenPipe.code == 32)             // EPIPE
        #expect(SyscallError.connectionReset.code == 104)       // ECONNRESET
        #expect(SyscallError.notConnected.code == 107)          // ENOTCONN
    }

    /// Distinct cases carry distinct codes, so a caller can tell failures apart.
    @Test func distinctCasesHaveDistinctCodes() {
        let all: [SyscallError] = [
            .noSuchFileOrDirectory, .interrupted, .badFileDescriptor, .wouldBlock, .noChildProcess,
            .isADirectory, .fileExists, .brokenPipe, .connectionReset, .notConnected, .invalidArgument,
        ]
        let codes = all.map(\.code)
        #expect(Set(codes).count == all.count)
    }

    /// Equatable conformance: like cases compare equal, unlike cases do not.
    @Test func equatableConformance() {
        #expect(SyscallError.wouldBlock == SyscallError.wouldBlock)
        #expect(SyscallError.noSuchFileOrDirectory != SyscallError.isADirectory)
        #expect(SyscallError.connectionReset != SyscallError.notConnected)
    }

    /// A thrown error can be caught and matched by case (typed-error usage).
    @Test func thrownErrorMatchesByCase() {
        func failing() throws { throw SyscallError.badFileDescriptor }
        #expect(throws: SyscallError.badFileDescriptor) { try failing() }
    }
}
