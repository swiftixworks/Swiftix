/// Go's `sync.RWMutex`, `sync.Cond`, and `sync.Mutex.TryLock` at run time.
///
/// A `sync.RWMutex` is the struct Go has, with Go's fields, and the VM does
/// with them what Go's `RWMutex` does: `readerCount` counts the readers and
/// goes negative by `maxReaders` while a writer holds or awaits the lock, so
/// a reader that arrives then waits; `readerWait` counts the readers a
/// waiting writer is still to see leave; the lock inside, `w`, is held by
/// the writer and passes between writers in the order they came. The state
/// is in the struct, which is where the variable is, so two elements of a
/// slice are two locks and a copy is the lock as it was, as in Go. Who is
/// parked is not in the struct: like Go's semaphores, the queues are kept by
/// the address (`GoAddress`, `GoLockWaiters`).
///
/// A native call is one instruction and nothing runs in the middle of it,
/// so what Go does with atomic operations and semaphores is done here in
/// one step: `Unlock` wakes every waiting reader, hands `w` to the next
/// writer, and has that writer announce itself, as it would on waking.
///
/// A `sync.Cond` has the two counters of Go's notification list, and its
/// waiters are kept by address as well. `Wait` is a function of the VM, not
/// a native, because it calls `c.L.Unlock()` and `c.L.Lock()`, methods of
/// whatever the program put in `L`.
/// Pure values and functions; no process or executor state.

/// Where a variable is: what a pointer to it says, in a form that can be
/// looked up. A lock and a condition variable keep their queues by it.
struct GoAddress: Hashable, Sendable {
    let cell: Int
    let path: [String]

    init(_ pointer: GoPointer) {
        cell = pointer.cell
        path = pointer.path.map { component in
            switch component {
            case .field(let name): return "." + name
            case .index(let index): return String(index)
            }
        }
    }
}

/// The goroutines parked on one `sync.RWMutex`.
struct GoLockWaiters: Sendable {
    /// Writers waiting for the lock inside, `w`, in the order they came.
    var writers: [Int] = []
    /// Readers waiting for a writer to finish.
    var readers: [Int] = []
    /// The writer that holds `w` and waits for the readers to leave.
    var pendingWriter: Int?
    /// What keeps the variable alive while somebody waits on it.
    let root: Int

    var isEmpty: Bool { writers.isEmpty && readers.isEmpty && pendingWriter == nil }
}

/// The goroutines parked on one `sync.Cond`, each with the ticket `Wait`
/// drew for it.
struct GoConditionWaiters: Sendable {
    var waiters: [(ticket: Int64, goroutineID: Int)] = []
    let root: Int
}

/// An error that ends a Go program at once, as the runtime's `fatal` does:
/// no deferred call runs and no `recover` sees it. Go prints
/// `fatal error: ` and the message.
struct GoFatalError: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String

    var description: String { "fatal error: " + message }

    static let readUnlockOfUnlocked = GoFatalError(message: "sync: RUnlock of unlocked RWMutex")
    static let unlockOfUnlocked = GoFatalError(message: "sync: Unlock of unlocked RWMutex")
}

enum GoSync {
    /// Reserved call names of the `sync` natives, with the number of
    /// operands each one pops. The receiver is a pointer to the struct, and
    /// for `sync.Mutex` the handle.
    static let argumentCounts: [String: Int] = [
        "$sync.Mutex.TryLock": 1,
        "$sync.RWMutex.Lock": 1,
        "$sync.RWMutex.Unlock": 1,
        "$sync.RWMutex.RLock": 1,
        "$sync.RWMutex.RUnlock": 1,
        "$sync.RWMutex.TryLock": 1,
        "$sync.RWMutex.TryRLock": 1,
        "$sync.RWMutex.RLocker": 1,
        "$sync.NewCond": 1,
        "$sync.Cond.Signal": 1,
        "$sync.Cond.Broadcast": 1,
        condAdd: 1,
        condWait: 2,
    ]

    /// The two halves of `(*sync.Cond).Wait` that the VM does itself: draw
    /// a ticket, and park until the ticket is called.
    static let condAdd = "$sync.Cond.add"
    static let condWait = "$sync.Cond.wait"

    /// Go's `rwmutexMaxReaders`.
    static let maxReaders: Int64 = 1 << 30

    /// What the VM reads and writes of a `sync.RWMutex`.
    struct ReadWriteState: Equatable {
        /// Whether a writer holds the lock inside.
        var isLocked: Bool
        var readerCount: Int64
        var readerWait: Int64

        /// The state the struct `value` holds, or nil when it is no
        /// `sync.RWMutex` as the compiler lays one out.
        init?(_ value: GoValue) {
            guard case .structure(let lock) = value, lock.fields.count == 5,
                case .structure(let inner) = lock.fields[0].value, inner.fields.count == 2,
                case .structure(let mutex) = inner.fields[1].value,
                case .int(let state)? = mutex.fields.first?.value,
                let readerCount = Self.counter(lock.fields[3].value),
                let readerWait = Self.counter(lock.fields[4].value)
            else { return nil }
            isLocked = state != 0
            self.readerCount = readerCount
            self.readerWait = readerWait
        }

        /// `value` with this state in it.
        func stored(in value: GoValue) -> GoValue {
            guard case .structure(var lock) = value, lock.fields.count == 5,
                case .structure(var inner) = lock.fields[0].value, inner.fields.count == 2,
                case .structure(var mutex) = inner.fields[1].value, !mutex.fields.isEmpty
            else { return value }
            mutex.fields[0].value = .int(isLocked ? 1 : 0)
            inner.fields[1].value = .structure(mutex)
            lock.fields[0].value = .structure(inner)
            lock.fields[3].value = Self.counter(readerCount, in: lock.fields[3].value)
            lock.fields[4].value = Self.counter(readerWait, in: lock.fields[4].value)
            return .structure(lock)
        }

        /// The number in an `atomic.Int32`, a struct of a mark and a value.
        private static func counter(_ value: GoValue) -> Int64? {
            guard case .structure(let atomic) = value, atomic.fields.count == 2,
                case .int(let number) = atomic.fields[1].value
            else { return nil }
            return number
        }

        private static func counter(_ number: Int64, in value: GoValue) -> GoValue {
            guard case .structure(var atomic) = value, atomic.fields.count == 2 else {
                return value
            }
            atomic.fields[1].value = .int(number)
            return .structure(atomic)
        }
    }

    /// The counters of a `sync.Cond`: how many tickets `Wait` has drawn and
    /// how many have been called. Go's `notifyList`.
    struct ConditionState: Equatable {
        var wait: Int64
        var notify: Int64

        init?(_ value: GoValue) {
            guard case .structure(let condition) = value, condition.fields.count == 3,
                case .structure(let list) = condition.fields[2].value, list.fields.count == 2,
                case .int(let wait) = list.fields[0].value,
                case .int(let notify) = list.fields[1].value
            else { return nil }
            self.wait = wait
            self.notify = notify
        }

        func stored(in value: GoValue) -> GoValue {
            guard case .structure(var condition) = value, condition.fields.count == 3,
                case .structure(var list) = condition.fields[2].value, list.fields.count == 2
            else { return value }
            // The counters are `uint32` and wrap as Go's do.
            list.fields[0].value = .int(wait & 0xFFFF_FFFF)
            list.fields[1].value = .int(notify & 0xFFFF_FFFF)
            condition.fields[2].value = .structure(list)
            return .structure(condition)
        }

        /// Go's `less` of two tickets, which holds across the wrap.
        static func isBefore(_ ticket: Int64, _ other: Int64) -> Bool {
            Int32(truncatingIfNeeded: ticket &- other) < 0
        }
    }

    /// A new `sync.Cond` around the locker `locker`: what `sync.NewCond`
    /// points to.
    static func condition(locker: GoValue) -> GoValue {
        .structure(
            GoStructValue(
                typeName: "sync.Cond",
                fields: [
                    GoStructFieldValue(name: "noCopy", value: .structure(GoStructValue(fields: []))),
                    GoStructFieldValue(name: "L", value: locker),
                    GoStructFieldValue(
                        name: "notify",
                        value: .structure(
                            GoStructValue(fields: [
                                GoStructFieldValue(name: "wait", value: .int(0)),
                                GoStructFieldValue(name: "notify", value: .int(0)),
                            ]))),
                ]))
    }

    /// The type name `(*sync.RWMutex).RLocker` boxes its pointer with: the
    /// descriptor of `*sync.rlocker`, a type defined as `sync.RWMutex` is.
    static let readLockerTypeName =
        GoTypeDescriptor.marker + "*N12:sync.rlocker\n12:sync.rlocker"
        + "S5;1:wS2;1:_S0;2:muS2;5:statel4:semaw9:writerSemw9:readerSemw"
        + "11:readerCountS2;1:_S0;1:vl10:readerWaitS2;1:_S0;1:vl"
}

/// The methods of the library's struct types, and of `*sync.Mutex`, as
/// functions of every program, under the names methods of a program's types
/// have: `*sync.RWMutex.RLock`. A call through an interface, a method value,
/// and an assertion to an interface find them there, as they find those of
/// `time.Duration` (`GoLibraryMethods`). Each loads its operands and makes
/// the native call; those of `*sync.Mutex` read the handle the pointer
/// points to and execute the instruction.
enum GoLibraryStructMethods {
    /// The pointer types that have methods here, without the `*`.
    static let owners: Set<String> = [
        "sync.Mutex", "sync.RWMutex", "sync.rlocker", "sync.Cond", "time.Timer", "time.Ticker",
    ]

    /// The types of `sync` that are handles, with no definition a
    /// descriptor could carry.
    static let handleNames: Set<String> = ["sync.Mutex", "sync.WaitGroup"]

    static let functions: [String: GoBytecodeFunction] = {
        var functions: [String: GoBytecodeFunction] = [:]
        func add(
            _ name: String, parameters: Int, results: Int = 0, locals: Int? = nil,
            _ body: [GoInstruction]
        ) {
            functions[name] = GoBytecodeFunction(
                name: name, parameterCount: parameters, returnCount: results,
                localCount: locals ?? parameters,
                instructions: body + [results == 0 ? .return : .returnValues(count: results)])
        }
        /// A method that is one native call on its operands.
        func native(_ owner: String, _ method: String, parameters: Int = 1, results: Int = 0) {
            add(
                "*\(owner).\(method)", parameters: parameters, results: results,
                (0..<parameters).map(GoInstruction.load)
                    + [.call("$\(owner).\(method)", argumentCount: parameters)])
        }

        let tryLock = GoInstruction.call("$sync.Mutex.TryLock", argumentCount: 1)
        add("*sync.Mutex.Lock", parameters: 1, [.load(0), .dereference, .mutexLock])
        add("*sync.Mutex.Unlock", parameters: 1, [.load(0), .dereference, .mutexUnlock])
        add("*sync.Mutex.TryLock", parameters: 1, results: 1, [.load(0), .dereference, tryLock])
        // The method value of a mutex holds its handle.
        add("sync.Mutex.TryLock", parameters: 1, results: 1, [.load(0), tryLock])

        for method in ["Lock", "Unlock", "RLock", "RUnlock"] { native("sync.RWMutex", method) }
        for method in ["TryLock", "TryRLock", "RLocker"] {
            native("sync.RWMutex", method, results: 1)
        }
        let read = GoInstruction.call("$sync.RWMutex.RLock", argumentCount: 1)
        let readDone = GoInstruction.call("$sync.RWMutex.RUnlock", argumentCount: 1)
        add("*sync.rlocker.Lock", parameters: 1, [.load(0), read])
        add("*sync.rlocker.Unlock", parameters: 1, [.load(0), readDone])

        native("time.Timer", "Stop", results: 1)
        native("time.Timer", "Reset", parameters: 2, results: 1)
        native("time.Ticker", "Stop")
        native("time.Ticker", "Reset", parameters: 2)

        native("sync.Cond", "Signal")
        native("sync.Cond", "Broadcast")
        // Go's `Wait`: draw a ticket, unlock, park until the ticket is
        // called, lock again. The lock is whatever `L` holds.
        let locker: [GoInstruction] = [.load(0), .dereference, .getField("L")]
        let wait: [GoInstruction] =
            [.load(0), .call(GoSync.condAdd, argumentCount: 1), .store(1)]
            + locker + [.callInterface("Unlock", argumentCount: 0)]
            + [.load(0), .load(1), .call(GoSync.condWait, argumentCount: 2)]
            + locker + [.callInterface("Lock", argumentCount: 0)]
        add("*sync.Cond.Wait", parameters: 1, locals: 2, wait)
        // What the compiler calls for `c.Wait()`.
        add("$sync.Cond.Wait", parameters: 1, locals: 2, wait)
        return functions
    }()

    /// Whether the dynamic type `owner` is one of these pointer types and
    /// implements `target`: it has a method of each name with as many
    /// parameters and results, unless the compiler, which knows the types,
    /// wrote that it does not.
    static func implements(_ owner: String, _ target: GoErrors.InterfaceTarget) -> Bool {
        guard owner.hasPrefix("*"), owners.contains(String(owner.dropFirst())),
            !target.methods.isEmpty,
            !target.implementers.contains(GoLibraryMethods.refusalMark + owner)
        else { return false }
        return target.methods.allSatisfy { wanted in
            guard let function = functions[owner + "." + wanted.name] else { return false }
            return function.parameterCount == wanted.parameterCount + 1
                && function.returnCount == wanted.resultCount
        }
    }
}
