//
//  Regex.swift
//  Swiftix
//
//  A small, self-contained regular-expression engine — pure standard library,
//  no Foundation (matching the core's constraint) — used by the text tools
//  (`grep`, `sed`, `awk`, `find -regex`-style predicates) so they can teach real
//  pattern matching instead of plain substring search.
//
//  It parses a POSIX-flavored pattern into an AST and matches with a
//  continuation-passing backtracking matcher over `[Character]`. Two syntaxes
//  share one AST:
//
//    - `.extended` (ERE, the default; `grep -E`, `sed -E`, `awk`): `|`, `( )`,
//      `* + ?`, `{n}` / `{n,}` / `{n,m}` are operators.
//    - `.basic` (BRE; plain `grep` and `sed`): only `*` is an operator; the
//      others are literal unless backslashed (`\( \)`, `\{ \}`, and the GNU
//      extensions `\|`, `\+`, `\?`). `^` anchors only at the start of a branch
//      and `$` only at its end.
//
//  Both support:
//    - literals and `.` (any character)
//    - anchors `^` and `$` — matching is line-oriented; a caller passes one line
//    - bracket expressions `[abc]`, ranges `[a-z]`, negation `[^…]`, a leading
//      `]`, and POSIX classes `[[:alpha:]]`, `[[:digit:]]`, `[[:space:]]`, …
//    - escapes `\d \w \s` (and `\D \W \S`), word boundaries `\b \B \< \>`,
//      `\n \t`, and escaped metacharacters
//    - capture groups with back-references `\1`…`\9`
//
//  This is a teaching-grade engine: greedy quantifiers only, leftmost match with
//  greedy (not POSIX leftmost-longest) alternation, and no locale collation. It
//  runs on the single loop-bound executor like the rest of the core and is a
//  plain value type, so it holds no state between matches and needs no locks.
//

/// A compiled regular expression. Construction parses the pattern once; matching
/// is then side-effect-free.
struct Regex {

    /// Which POSIX dialect a pattern is written in.
    enum Syntax {
        case extended
        case basic
    }

    /// A successful match: the overall range plus each capture group's range
    /// (`groups[0]` is the whole match; an unmatched group is `nil`). Ranges
    /// index the `[Character]` array that was searched.
    struct Match {
        let range: Range<Int>
        let groups: [Range<Int>?]
    }

    /// The parsed pattern tree.
    private let root: Node
    private let ignoreCase: Bool
    /// Number of capture groups in the pattern (not counting group 0).
    let groupCount: Int

    /// The AST for the supported subset.
    private indirect enum Node {
        /// Matches the empty string (e.g. an empty alternative).
        case empty
        /// A single literal character.
        case literal(Character)
        /// `.` — any single character.
        case anyChar
        /// A character class (`[...]`), carrying whether it is negated.
        case charClass(negated: Bool, members: [ClassMember])
        /// `^` — the start of the (line) input.
        case startAnchor
        /// `$` — the end of the (line) input.
        case endAnchor
        /// `\b` (boundary), `\B` (not a boundary), `\<` (word start), `\>` (word end).
        case wordBoundary(WordEdge)
        /// A sequence of nodes matched in order.
        case concat([Node])
        /// A set of alternatives; matches if any one matches.
        case alternation([Node])
        /// A greedy quantifier over `node`, matching between `min` and `max`
        /// repetitions (`max == nil` means unbounded).
        case quantified(Node, min: Int, max: Int?)
        /// A capture group with its 1-based index.
        case group(Node, index: Int)
        /// `\N` — the text captured by group N.
        case backReference(Int)

        /// Whether the node always consumes exactly one character (so a
        /// quantifier over it can iterate instead of recursing).
        var isSingleCharacter: Bool {
            switch self {
            case .literal, .anyChar, .charClass: return true
            default: return false
            }
        }
    }

    private enum WordEdge {
        case boundary, notBoundary, start, end
    }

    /// One member of a character class.
    private enum ClassMember {
        case single(Character)
        case range(Character, Character)
        case predefined(Predefined)

        func matches(_ character: Character) -> Bool {
            switch self {
            case let .single(value):
                return character == value
            case let .range(low, high):
                return character >= low && character <= high
            case let .predefined(kind):
                return kind.matches(character)
            }
        }
    }

    /// A predefined class: the `\d \w \s` shorthands, their negations, and the
    /// POSIX `[:name:]` classes.
    private enum Predefined {
        case digit, notDigit, word, notWord, space, notSpace
        case alpha, alnum, upper, lower, punct, blank, xdigit, cntrl, print, graph

        func matches(_ character: Character) -> Bool {
            switch self {
            case .digit:    return character.isASCII && character.isNumber
            case .notDigit: return !(character.isASCII && character.isNumber)
            case .word:     return Regex.isWordCharacter(character)
            case .notWord:  return !Regex.isWordCharacter(character)
            case .space:    return Regex.isSpace(character)
            case .notSpace: return !Regex.isSpace(character)
            case .alpha:    return character.isLetter
            case .alnum:    return character.isLetter || character.isNumber
            case .upper:    return character.isUppercase
            case .lower:    return character.isLowercase
            case .punct:    return character.isASCII && (character.isPunctuation || character.isSymbol)
            case .blank:    return character == " " || character == "\t"
            case .xdigit:   return character.isHexDigit
            case .cntrl:
                guard let value = character.asciiValue else { return false }
                return value < 0x20 || value == 0x7F
            case .print:
                guard let value = character.asciiValue else { return true }
                return value >= 0x20 && value != 0x7F
            case .graph:
                guard let value = character.asciiValue else { return true }
                return value > 0x20 && value != 0x7F
            }
        }

        static func named(_ name: String) -> Predefined? {
            switch name {
            case "alpha": return .alpha
            case "digit": return .digit
            case "alnum": return .alnum
            case "upper": return .upper
            case "lower": return .lower
            case "space": return .space
            case "punct": return .punct
            case "blank": return .blank
            case "xdigit": return .xdigit
            case "cntrl": return .cntrl
            case "print": return .print
            case "graph": return .graph
            default: return nil
            }
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
            || character == "\u{0B}" || character == "\u{0C}"
    }

    // MARK: - Construction

    /// Compile `pattern`, or return `nil` if it is malformed. When
    /// `ignoreCase` is set, matching is case-insensitive.
    init?(pattern: String, ignoreCase: Bool = false, syntax: Syntax = .extended) {
        var parser = Parser(pattern: Array(pattern), ignoreCase: ignoreCase, syntax: syntax)
        guard let node = parser.parse() else { return nil }
        self.root = node
        self.ignoreCase = ignoreCase
        self.groupCount = parser.groupCount
    }

    /// Build a regex that matches `text` literally (all metacharacters escaped)
    /// — the engine behind `grep -F`. Never fails.
    static func literal(_ text: String, ignoreCase: Bool = false) -> Regex {
        let nodes = text.map { Node.literal(ignoreCase ? Regex.fold($0) : $0) }
        return Regex(root: .concat(nodes), ignoreCase: ignoreCase)
    }

    private init(root: Node, ignoreCase: Bool) {
        self.root = root
        self.ignoreCase = ignoreCase
        self.groupCount = 0
    }

    private static func fold(_ character: Character) -> Character {
        let lowered = character.lowercased()
        return lowered.count == 1 ? Character(lowered) : character
    }

    // MARK: - Matching

    /// Whether the pattern matches anywhere in `line` (an unanchored search, like
    /// `grep`). `^` still pins to the line start and `$` to the line end.
    func matches(_ line: String) -> Bool {
        match(in: Array(line), from: 0) != nil
    }

    /// The leftmost match at or after `start`, as a half-open index range into
    /// `characters`, or `nil` if the pattern does not match there. The match is
    /// greedy (longest at the leftmost start). Positions are relative to the
    /// *original* characters; case folding for an ignore-case regex is applied
    /// 1:1 internally, so a caller can slice and splice `characters` directly
    /// (this is what `sed`'s substitution needs).
    func firstMatch(in characters: [Character], from start: Int) -> Range<Int>? {
        match(in: characters, from: start)?.range
    }

    /// The leftmost match at or after `start`, with its capture groups.
    func match(in characters: [Character], from start: Int) -> Match? {
        guard start >= 0, start <= characters.count else { return nil }
        let state = MatchState(input: ignoreCase ? characters.map(Regex.fold) : characters,
                               groupCount: groupCount)
        for begin in start...characters.count {
            for index in state.captures.indices { state.captures[index] = nil }
            var matchEnd: Int?
            // The matcher is greedy, so the first end handed to the continuation
            // is the preferred match starting at `begin`.
            _ = match(root, state, begin) { end in matchEnd = end; return true }
            if let end = matchEnd {
                return Match(range: begin..<end, groups: [begin..<end] + state.captures)
            }
        }
        return nil
    }

    /// Whether the pattern matches the *whole* of `characters` (`grep -x`).
    func matchesEntire(_ characters: [Character]) -> Bool {
        let state = MatchState(input: ignoreCase ? characters.map(Regex.fold) : characters,
                               groupCount: groupCount)
        return match(root, state, 0) { $0 == characters.count }
    }

    /// Mutable per-search state: the (case-folded) input and the capture slots.
    private final class MatchState {
        let input: [Character]
        var captures: [Range<Int>?]

        init(input: [Character], groupCount: Int) {
            self.input = input
            self.captures = Array(repeating: nil, count: groupCount)
        }
    }

    private func matchesSingle(_ node: Node, _ character: Character) -> Bool {
        switch node {
        case let .literal(expected):
            return character == expected
        case .anyChar:
            return true
        case let .charClass(negated, members):
            var hit = members.contains { $0.matches(character) }
            if !hit, ignoreCase {
                // The input is folded to lowercase; a class such as `[A-Z]` or
                // `[[:upper:]]` must still accept it.
                let upper = character.uppercased()
                if upper.count == 1 {
                    let alternate = Character(upper)
                    hit = members.contains { $0.matches(alternate) }
                }
            }
            return hit != negated
        default:
            return false
        }
    }

    /// Core backtracking matcher. Attempts to match `node` at `position`,
    /// invoking `continuation` with the position just past the match; returns
    /// whether some path (matching `node` then the continuation) succeeds.
    private func match(_ node: Node,
                       _ state: MatchState,
                       _ position: Int,
                       _ continuation: (Int) -> Bool) -> Bool {
        let input = state.input
        switch node {
        case .empty:
            return continuation(position)

        case .literal, .anyChar, .charClass:
            guard position < input.count, matchesSingle(node, input[position]) else { return false }
            return continuation(position + 1)

        case .startAnchor:
            return position == 0 && continuation(position)

        case .endAnchor:
            return position == input.count && continuation(position)

        case let .wordBoundary(edge):
            let before = position > 0 && Regex.isWordCharacter(input[position - 1])
            let after = position < input.count && Regex.isWordCharacter(input[position])
            let ok: Bool
            switch edge {
            case .boundary:    ok = before != after
            case .notBoundary: ok = before == after
            case .start:       ok = !before && after
            case .end:         ok = before && !after
            }
            return ok && continuation(position)

        case let .concat(nodes):
            return matchSequence(nodes[...], state, position, continuation)

        case let .alternation(options):
            for option in options where match(option, state, position, continuation) {
                return true
            }
            return false

        case let .quantified(inner, min, max):
            if inner.isSingleCharacter {
                // Iterative fast path: count the run, then give back one at a time.
                var count = 0
                while position + count < input.count,
                      max.map({ count < $0 }) ?? true,
                      matchesSingle(inner, input[position + count]) {
                    count += 1
                }
                guard count >= min else { return false }
                var taken = count
                while taken >= min {
                    if continuation(position + taken) { return true }
                    taken -= 1
                }
                return false
            }
            return matchQuantified(inner, min: min, max: max, count: 0,
                                   state, position, continuation)

        case let .group(inner, index):
            let saved = state.captures[index - 1]
            if match(inner, state, position, { end in
                let previous = state.captures[index - 1]
                state.captures[index - 1] = position..<end
                if continuation(end) { return true }
                state.captures[index - 1] = previous
                return false
            }) {
                return true
            }
            state.captures[index - 1] = saved
            return false

        case let .backReference(index):
            guard index >= 1, index <= state.captures.count,
                  let captured = state.captures[index - 1] else { return false }
            let length = captured.count
            guard position + length <= input.count else { return false }
            for offset in 0..<length where input[captured.lowerBound + offset] != input[position + offset] {
                return false
            }
            return continuation(position + length)
        }
    }

    /// Match `nodes` in order, threading the position through each.
    private func matchSequence(_ nodes: ArraySlice<Node>,
                               _ state: MatchState,
                               _ position: Int,
                               _ continuation: (Int) -> Bool) -> Bool {
        guard let first = nodes.first else { return continuation(position) }
        let rest = nodes.dropFirst()
        return match(first, state, position) { next in
            matchSequence(rest, state, next, continuation)
        }
    }

    /// Greedy repetition: try to match `inner` once more (up to `max`), then fall
    /// back to the continuation once at least `min` repetitions are done. The
    /// empty-progress guard prevents an infinite loop when `inner` can match the
    /// empty string.
    private func matchQuantified(_ inner: Node,
                                 min: Int,
                                 max: Int?,
                                 count: Int,
                                 _ state: MatchState,
                                 _ position: Int,
                                 _ continuation: (Int) -> Bool) -> Bool {
        if max.map({ count < $0 }) ?? true {
            let advanced = match(inner, state, position) { next in
                if next == position, count >= min { return false }
                return matchQuantified(inner, min: min, max: max, count: count + 1,
                                       state, next, continuation)
            }
            if advanced { return true }
        }
        return count >= min && continuation(position)
    }

    // MARK: - Parser

    /// Recursive-descent parser over the pattern characters.
    private struct Parser {
        private let pattern: [Character]
        private let ignoreCase: Bool
        private let syntax: Syntax
        private var index = 0
        private(set) var groupCount = 0

        init(pattern: [Character], ignoreCase: Bool, syntax: Syntax) {
            self.pattern = pattern
            self.ignoreCase = ignoreCase
            self.syntax = syntax
        }

        mutating func parse() -> Node? {
            guard let node = parseAlternation() else { return nil }
            // Anything left over is an unbalanced `)`.
            return index == pattern.count ? node : nil
        }

        private var isBasic: Bool { syntax == .basic }

        /// Whether the parser is positioned at `\` followed by `character`.
        private func atEscaped(_ character: Character) -> Bool {
            peek() == "\\" && peek(at: 1) == character
        }

        private func atAlternationBar() -> Bool {
            isBasic ? atEscaped("|") : peek() == "|"
        }

        private func atGroupClose() -> Bool {
            isBasic ? atEscaped(")") : peek() == ")"
        }

        private mutating func parseAlternation() -> Node? {
            var options: [Node] = []
            guard let first = parseConcat() else { return nil }
            options.append(first)
            while atAlternationBar() {
                index += isBasic ? 2 : 1
                guard let next = parseConcat() else { return nil }
                options.append(next)
            }
            return options.count == 1 ? options[0] : .alternation(options)
        }

        private mutating func parseConcat() -> Node? {
            var nodes: [Node] = []
            var atBranchStart = true
            while index < pattern.count, !atAlternationBar(), !atGroupClose() {
                guard let node = parseRepeat(atBranchStart: atBranchStart) else { return nil }
                nodes.append(node)
                atBranchStart = false
            }
            if nodes.isEmpty { return .empty }
            return nodes.count == 1 ? nodes[0] : .concat(nodes)
        }

        private mutating func parseRepeat(atBranchStart: Bool) -> Node? {
            // A quantifier with nothing to repeat is a literal in both dialects
            // (`*` leading a BRE; tolerated in an ERE the way GNU does).
            if atBranchStart, let c = peek(), c == "*" || (!isBasic && (c == "+" || c == "?")) {
                index += 1
                return .literal(fold(c))
            }
            guard var node = parseAtom(atBranchStart: atBranchStart) else { return nil }
            while index < pattern.count {
                if peek() == "*" {
                    index += 1
                    node = .quantified(node, min: 0, max: nil)
                } else if !isBasic, peek() == "+" {
                    index += 1
                    node = .quantified(node, min: 1, max: nil)
                } else if !isBasic, peek() == "?" {
                    index += 1
                    node = .quantified(node, min: 0, max: 1)
                } else if isBasic, atEscaped("+") {
                    index += 2
                    node = .quantified(node, min: 1, max: nil)
                } else if isBasic, atEscaped("?") {
                    index += 2
                    node = .quantified(node, min: 0, max: 1)
                } else if !isBasic, peek() == "{" {
                    if let bounds = parseBounds(openLength: 1) {
                        node = .quantified(node, min: bounds.min, max: bounds.max)
                    } else if let next = peek(at: 1), next.isASCII, next.isNumber {
                        return nil                       // `{3,2}` and the like: a malformed bound
                    } else {
                        break                            // a `{` that starts no bound is a literal
                    }
                } else if isBasic, atEscaped("{") {
                    guard let bounds = parseBounds(openLength: 2) else { return nil }
                    node = .quantified(node, min: bounds.min, max: bounds.max)
                } else {
                    break
                }
            }
            return node
        }

        /// Parse `{n}`, `{n,}`, or `{n,m}` (or the `\{…\}` BRE spelling). Leaves
        /// the position untouched and returns `nil` when the text is not a valid
        /// bound, so an ERE `{` can then be taken literally.
        private mutating func parseBounds(openLength: Int) -> (min: Int, max: Int?)? {
            let start = index
            index += openLength
            func fail(_ parser: inout Parser) -> (min: Int, max: Int?)? {
                parser.index = start
                return nil
            }
            var minText = ""
            while let c = peek(), c.isASCII, c.isNumber { minText.append(c); index += 1 }
            guard let minimum = Int(minText) else { return fail(&self) }
            var maximum: Int? = minimum
            if peek() == "," {
                index += 1
                var maxText = ""
                while let c = peek(), c.isASCII, c.isNumber { maxText.append(c); index += 1 }
                if maxText.isEmpty {
                    maximum = nil
                } else {
                    guard let value = Int(maxText), value >= minimum else { return fail(&self) }
                    maximum = value
                }
            }
            if isBasic {
                guard atEscaped("}") else { return fail(&self) }
                index += 2
            } else {
                guard peek() == "}" else { return fail(&self) }
                index += 1
            }
            return (minimum, maximum)
        }

        private mutating func parseAtom(atBranchStart: Bool) -> Node? {
            guard let c = peek() else { return nil }
            switch c {
            case "(" where !isBasic:
                index += 1
                return parseGroupBody(closeLength: 1)
            case ")" where !isBasic:
                return nil
            case "[":
                index += 1
                return parseCharClass()
            case ".":
                index += 1
                return .anyChar
            case "^":
                index += 1
                // In a BRE `^` is an anchor only at the start of a branch.
                return (!isBasic || atBranchStart) ? .startAnchor : .literal("^")
            case "$":
                index += 1
                // In a BRE `$` is an anchor only at the end of a branch.
                if isBasic, index < pattern.count, !atAlternationBar(), !atGroupClose() {
                    return .literal("$")
                }
                return .endAnchor
            case "\\":
                index += 1
                return parseEscape()
            default:
                index += 1
                return .literal(fold(c))
            }
        }

        private mutating func parseGroupBody(closeLength: Int) -> Node? {
            groupCount += 1
            let number = groupCount
            guard let inner = parseAlternation(), atGroupClose() else { return nil }
            index += closeLength
            return .group(inner, index: number)
        }

        private mutating func parseEscape() -> Node? {
            guard let c = peek() else { return nil }   // trailing backslash
            index += 1
            switch c {
            case "d": return .charClass(negated: false, members: [.predefined(.digit)])
            case "D": return .charClass(negated: false, members: [.predefined(.notDigit)])
            case "w": return .charClass(negated: false, members: [.predefined(.word)])
            case "W": return .charClass(negated: false, members: [.predefined(.notWord)])
            case "s": return .charClass(negated: false, members: [.predefined(.space)])
            case "S": return .charClass(negated: false, members: [.predefined(.notSpace)])
            case "b": return .wordBoundary(.boundary)
            case "B": return .wordBoundary(.notBoundary)
            case "<": return .wordBoundary(.start)
            case ">": return .wordBoundary(.end)
            case "n": return .literal("\n")
            case "t": return .literal("\t")
            case "(" where isBasic:
                return parseGroupBody(closeLength: 2)
            case ")" where isBasic:
                return nil
            case "1"..."9":
                guard let number = c.wholeNumberValue, number <= groupCount else { return nil }
                return .backReference(number)
            default:
                return .literal(fold(c))   // escaped metacharacter → literal
            }
        }

        private mutating func parseCharClass() -> Node? {
            var negated = false
            if peek() == "^" { negated = true; index += 1 }
            var members: [ClassMember] = []
            var first = true
            while let c = peek(), first || c != "]" {
                first = false
                // POSIX class `[:name:]`.
                if c == "[", peek(at: 1) == ":" {
                    var name = ""
                    var cursor = index + 2
                    while cursor < pattern.count, pattern[cursor] != ":" {
                        name.append(pattern[cursor])
                        cursor += 1
                    }
                    guard cursor + 1 < pattern.count, pattern[cursor + 1] == "]",
                          let kind = Predefined.named(name) else { return nil }
                    members.append(.predefined(kind))
                    if ignoreCase, kind == .upper || kind == .lower {
                        members.append(.predefined(.alpha))
                    }
                    index = cursor + 2
                    continue
                }
                var low = c
                index += 1
                if c == "\\", let escaped = peek() {
                    // Shorthand escapes are accepted inside a class as a
                    // convenience (`[\d_]`); any other escape is the character.
                    index += 1
                    switch escaped {
                    case "d": members.append(.predefined(.digit)); continue
                    case "w": members.append(.predefined(.word)); continue
                    case "s": members.append(.predefined(.space)); continue
                    case "n": low = "\n"
                    case "t": low = "\t"
                    default: low = escaped
                    }
                }
                // A range `low-high` (a trailing `-` is a literal dash).
                if peek() == "-", let high = peek(at: 1), high != "]" {
                    index += 2
                    let lo = fold(low), hi = fold(high)
                    guard lo <= hi else { return nil }
                    members.append(.range(lo, hi))
                } else {
                    members.append(.single(fold(low)))
                }
            }
            guard peek() == "]" else { return nil }   // unterminated class
            index += 1
            return .charClass(negated: negated, members: members)
        }

        private func peek() -> Character? {
            index < pattern.count ? pattern[index] : nil
        }

        private func peek(at offset: Int) -> Character? {
            let target = index + offset
            return target < pattern.count ? pattern[target] : nil
        }

        /// Lowercase a literal when compiling an ignore-case pattern, so it
        /// compares against the lowercased input.
        private func fold(_ character: Character) -> Character {
            ignoreCase ? Regex.fold(character) : character
        }
    }
}
