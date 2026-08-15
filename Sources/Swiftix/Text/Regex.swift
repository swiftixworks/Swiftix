//
//  Regex.swift
//  Swiftix
//
//  A small, self-contained regular-expression engine — pure standard library,
//  no Foundation (matching the core's constraint) — used by the text tools
//  (`grep` and `sed`) so they can teach real pattern matching
//  instead of plain substring search.
//
//  It parses an ERE-flavored subset into an AST and matches with a
//  continuation-passing backtracking matcher over `[Character]`. Supported
//  syntax:
//    - literals and `.` (any character)
//    - anchors `^` (start) and `$` (end) — matching is line-oriented, so a
//      caller passes one line at a time
//    - quantifiers `*`, `+`, `?`, and bounded `{n}` / `{n,}` / `{n,m}` (greedy)
//    - groups `( … )` and alternation `a|b`
//    - character classes `[abc]`, ranges `[a-z]`, negation `[^…]`
//    - escapes `\d \w \s` (and negated `\D \W \S`) plus escaped metacharacters
//
//  This is a teaching-grade engine, not a POSIX-complete one: there are no
//  capture-group backreferences, no lazy quantifiers, and no locale collation.
//  It runs on the single loop-bound executor like the rest of the core and is a
//  plain value type, so it holds no state between matches and needs no locks.
//

/// A compiled regular expression. Construction parses the pattern once; matching
/// is then allocation-light and side-effect-free.
struct Regex {

    /// The parsed pattern tree.
    private let root: Node

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
        /// A sequence of nodes matched in order.
        case concat([Node])
        /// A set of alternatives; matches if any one matches.
        case alternation([Node])
        /// A greedy quantifier over `node`, matching between `min` and `max`
        /// repetitions (`max == nil` means unbounded).
        case quantified(Node, min: Int, max: Int?)
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

    /// A predefined class shorthand (`\d`, `\w`, `\s` and their negations).
    private enum Predefined {
        case digit, notDigit, word, notWord, space, notSpace

        func matches(_ character: Character) -> Bool {
            switch self {
            case .digit:    return character.isASCII && character.isNumber
            case .notDigit: return !(character.isASCII && character.isNumber)
            case .word:     return character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
            case .notWord:  return !(character == "_" || (character.isASCII && (character.isLetter || character.isNumber)))
            case .space:    return character == " " || character == "\t" || character == "\n" || character == "\r"
            case .notSpace: return !(character == " " || character == "\t" || character == "\n" || character == "\r")
            }
        }
    }

    // MARK: - Construction

    /// Compile `pattern`, or return `nil` if it is malformed. When
    /// `ignoreCase` is set, matching is case-insensitive.
    init?(pattern: String, ignoreCase: Bool = false) {
        var parser = Parser(pattern: Array(pattern), ignoreCase: ignoreCase)
        guard let node = parser.parse() else { return nil }
        self.root = node
        self.ignoreCase = ignoreCase
    }

    /// Build a regex that matches `text` literally (all metacharacters escaped)
    /// — the engine behind `grep -F`. Never fails.
    static func literal(_ text: String, ignoreCase: Bool = false) -> Regex {
        let nodes = text.map { Node.literal(ignoreCase ? Character($0.lowercased()) : $0) }
        return Regex(root: .concat(nodes), ignoreCase: ignoreCase)
    }

    private init(root: Node, ignoreCase: Bool) {
        self.root = root
        self.ignoreCase = ignoreCase
    }

    private let ignoreCase: Bool

    // MARK: - Matching

    /// Whether the pattern matches anywhere in `line` (an unanchored search, like
    /// `grep`). `^` still pins to the line start and `$` to the line end.
    func matches(_ line: String) -> Bool {
        let characters = Array(ignoreCase ? line.lowercased() : line)
        // Try every starting offset (including the end, so `a*`/`^$` can match an
        // empty span). Anchors inside the pattern reject invalid start offsets.
        for start in 0...characters.count {
            if match(root, characters, start, { _ in true }) {
                return true
            }
        }
        return false
    }

    /// The leftmost match at or after `start`, as a half-open index range into
    /// `characters`, or `nil` if the pattern does not match there. The match is
    /// greedy (longest at the leftmost start), matching `matches`' semantics.
    /// Positions are relative to the *original* characters; case folding for an
    /// ignore-case regex is applied 1:1 internally, so a caller can slice and
    /// splice `characters` directly (this is what `sed`'s substitution needs).
    func firstMatch(in characters: [Character], from start: Int) -> Range<Int>? {
        let haystack = ignoreCase ? characters.map { Character($0.lowercased()) } : characters
        guard start >= 0, start <= haystack.count else { return nil }
        for begin in start...haystack.count {
            var matchEnd: Int?
            // The matcher is greedy, so the first end handed to the continuation
            // is the longest match starting at `begin`.
            _ = match(root, haystack, begin) { end in matchEnd = end; return true }
            if let end = matchEnd { return begin..<end }
        }
        return nil
    }

    /// Core backtracking matcher. Attempts to match `node` at `position` in
    /// `characters`, invoking `continuation` with the position just past the
    /// match; returns whether some path (matching `node` then the continuation)
    /// succeeds.
    private func match(_ node: Node,
                       _ characters: [Character],
                       _ position: Int,
                       _ continuation: (Int) -> Bool) -> Bool {
        switch node {
        case .empty:
            return continuation(position)

        case let .literal(value):
            guard position < characters.count, characters[position] == value else { return false }
            return continuation(position + 1)

        case .anyChar:
            guard position < characters.count else { return false }
            return continuation(position + 1)

        case let .charClass(negated, members):
            guard position < characters.count else { return false }
            let isMember = members.contains { $0.matches(characters[position]) }
            guard isMember != negated else { return false }
            return continuation(position + 1)

        case .startAnchor:
            return position == 0 ? continuation(position) : false

        case .endAnchor:
            return position == characters.count ? continuation(position) : false

        case let .concat(nodes):
            return matchSequence(nodes, 0, characters, position, continuation)

        case let .alternation(options):
            for option in options where match(option, characters, position, continuation) {
                return true
            }
            return false

        case let .quantified(inner, min, max):
            return matchQuantified(inner, min: min, max: max, characters, position, matched: 0, continuation)
        }
    }

    /// Match a concatenation node-by-node, threading the continuation so a later
    /// node's failure backtracks into an earlier node's choices.
    private func matchSequence(_ nodes: [Node],
                               _ index: Int,
                               _ characters: [Character],
                               _ position: Int,
                               _ continuation: (Int) -> Bool) -> Bool {
        if index >= nodes.count { return continuation(position) }
        return match(nodes[index], characters, position) { next in
            matchSequence(nodes, index + 1, characters, next, continuation)
        }
    }

    /// Greedy quantifier match: consume as many repetitions as possible (up to
    /// `max`), backtracking toward `min` until the continuation succeeds. The
    /// empty-progress guard prevents an infinite loop when `inner` can match
    /// nothing (e.g. `(a?)*`).
    private func matchQuantified(_ inner: Node,
                                 min: Int,
                                 max: Int?,
                                 _ characters: [Character],
                                 _ position: Int,
                                 matched: Int,
                                 _ continuation: (Int) -> Bool) -> Bool {
        if max == nil || matched < max! {
            let extended = match(inner, characters, position) { next in
                guard next != position else { return false }   // no forward progress: stop
                return matchQuantified(inner, min: min, max: max, characters, next,
                                       matched: matched + 1, continuation)
            }
            if extended { return true }
        }
        // Greedy path exhausted (or blocked): accept here if we have met `min`.
        return matched >= min ? continuation(position) : false
    }

    // MARK: - Parser

    /// A recursive-descent parser for the supported ERE subset. Produces a `Node`
    /// tree, or `nil` on a syntax error (unbalanced `(`/`[`, bad `{n,m}`, …).
    private struct Parser {
        let pattern: [Character]
        let ignoreCase: Bool
        var index = 0

        init(pattern: [Character], ignoreCase: Bool) {
            self.pattern = pattern
            self.ignoreCase = ignoreCase
        }

        mutating func parse() -> Node? {
            guard let node = parseAlternation() else { return nil }
            guard index == pattern.count else { return nil }   // trailing junk (e.g. stray `)`)
            return node
        }

        // alternation := concat ('|' concat)*
        private mutating func parseAlternation() -> Node? {
            guard let first = parseConcat() else { return nil }
            var options = [first]
            while peek() == "|" {
                index += 1
                guard let next = parseConcat() else { return nil }
                options.append(next)
            }
            return options.count == 1 ? first : .alternation(options)
        }

        // concat := repeat*
        private mutating func parseConcat() -> Node? {
            var nodes: [Node] = []
            while let character = peek(), character != "|", character != ")" {
                guard let node = parseRepeat() else { return nil }
                nodes.append(node)
            }
            if nodes.isEmpty { return .empty }
            return nodes.count == 1 ? nodes[0] : .concat(nodes)
        }

        // repeat := atom quantifier?
        private mutating func parseRepeat() -> Node? {
            guard let atom = parseAtom() else { return nil }
            guard let character = peek() else { return atom }
            switch character {
            case "*": index += 1; return .quantified(atom, min: 0, max: nil)
            case "+": index += 1; return .quantified(atom, min: 1, max: nil)
            case "?": index += 1; return .quantified(atom, min: 0, max: 1)
            case "{": return parseBrace(atom)
            default:  return atom
            }
        }

        // Parse `{n}`, `{n,}`, or `{n,m}` following `atom`. A `{` that is not a
        // valid bound is treated as a literal brace (lenient, like grep).
        private mutating func parseBrace(_ atom: Node) -> Node? {
            let save = index
            index += 1   // consume '{'
            var lowDigits = ""
            while let character = peek(), character.isNumber { lowDigits.append(character); index += 1 }
            guard !lowDigits.isEmpty, let low = Int(lowDigits) else {
                index = save
                return .literal("{")   // not a real bound: literal brace
            }
            var high: Int? = low
            if peek() == "," {
                index += 1
                var highDigits = ""
                while let character = peek(), character.isNumber { highDigits.append(character); index += 1 }
                high = highDigits.isEmpty ? nil : Int(highDigits)
            }
            guard peek() == "}" else { index = save; return .literal("{") }
            index += 1   // consume '}'
            if let high, high < low { return nil }
            return .quantified(atom, min: low, max: high)
        }

        // atom := '(' alternation ')' | '[' class ']' | '.' | '^' | '$'
        //       | '\' escape | literal
        private mutating func parseAtom() -> Node? {
            guard let character = peek() else { return nil }
            switch character {
            case "(":
                index += 1
                guard let inner = parseAlternation() else { return nil }
                guard peek() == ")" else { return nil }
                index += 1
                return inner
            case "[":
                return parseCharClass()
            case ".":
                index += 1
                return .anyChar
            case "^":
                index += 1
                return .startAnchor
            case "$":
                index += 1
                return .endAnchor
            case ")", "|":
                return nil   // handled by the caller; not a valid atom start
            case "*", "+", "?":
                return nil   // a quantifier with nothing to quantify
            case "\\":
                return parseEscape()
            default:
                index += 1
                return .literal(fold(character))
            }
        }

        // Parse a backslash escape: a predefined class (\d \w \s …) or an escaped
        // literal metacharacter.
        private mutating func parseEscape() -> Node? {
            index += 1   // consume '\'
            guard let character = peek() else { return nil }   // dangling backslash
            index += 1
            switch character {
            case "d": return .charClass(negated: false, members: [.predefined(.digit)])
            case "D": return .charClass(negated: false, members: [.predefined(.notDigit)])
            case "w": return .charClass(negated: false, members: [.predefined(.word)])
            case "W": return .charClass(negated: false, members: [.predefined(.notWord)])
            case "s": return .charClass(negated: false, members: [.predefined(.space)])
            case "S": return .charClass(negated: false, members: [.predefined(.notSpace)])
            case "n": return .literal("\n")
            case "t": return .literal("\t")
            case "r": return .literal("\r")
            default:  return .literal(fold(character))   // escaped metacharacter → literal
            }
        }

        // Parse a `[...]` character class (after the opening `[`).
        private mutating func parseCharClass() -> Node? {
            index += 1   // consume '['
            var negated = false
            if peek() == "^" { negated = true; index += 1 }
            var members: [ClassMember] = []
            // A `]` immediately after `[` or `[^` is a literal `]`.
            if peek() == "]" { members.append(.single("]")); index += 1 }
            while let character = peek(), character != "]" {
                if character == "\\" {
                    index += 1
                    guard let escaped = peek() else { return nil }
                    index += 1
                    switch escaped {
                    case "d": members.append(.predefined(.digit))
                    case "D": members.append(.predefined(.notDigit))
                    case "w": members.append(.predefined(.word))
                    case "W": members.append(.predefined(.notWord))
                    case "s": members.append(.predefined(.space))
                    case "S": members.append(.predefined(.notSpace))
                    case "n": members.append(.single("\n"))
                    case "t": members.append(.single("\t"))
                    case "r": members.append(.single("\r"))
                    default:  members.append(.single(fold(escaped)))
                    }
                    continue
                }
                // A range `a-z`: a `-` between two literals (not first/last).
                if let next = peek(at: 1), next == "-", let after = peek(at: 2), after != "]" {
                    let low = fold(character)
                    index += 2   // consume the low char and '-'
                    let highChar = pattern[index]
                    index += 1
                    members.append(.range(low, fold(highChar)))
                } else {
                    members.append(.single(fold(character)))
                    index += 1
                }
            }
            guard peek() == "]" else { return nil }   // unterminated class
            index += 1
            return .charClass(negated: negated, members: members)
        }

        // MARK: Parser helpers

        private func peek() -> Character? {
            index < pattern.count ? pattern[index] : nil
        }

        private func peek(at offset: Int) -> Character? {
            let target = index + offset
            return target < pattern.count ? pattern[target] : nil
        }

        /// Case-fold a literal when the regex is case-insensitive (the input side
        /// is lowercased in `matches`, so the pattern side must match).
        private func fold(_ character: Character) -> Character {
            ignoreCase ? Character(character.lowercased()) : character
        }
    }
}
