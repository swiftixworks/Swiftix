/// Name service for users and groups: a parsed view of `/etc/passwd` and
/// `/etc/group` with a synthetic fallback for identities those files do not
/// list.
///
/// Credentials in the kernel are purely numeric. This type is the one place
/// that maps them to and from names, so `id`, `whoami`, `who`, `su`, `ls -l`,
/// and the shell prompt agree. The files are ordinary VFS content shipped by a
/// distribution; when they are absent (or do not mention an id) the historical
/// synthetic names apply: uid 0 is `root`, any other uid `N` is `userN` with a
/// same-numbered primary group.
///
/// Concurrency: an immutable value snapshot taken on the kernel's serial
/// executor; it does not observe later edits to the files.
struct UserDatabase: Equatable {
    /// One `/etc/passwd` record (`name:password:uid:gid:gecos:home:shell`).
    struct User: Equatable {
        let name: String
        let uid: UInt32
        let gid: UInt32
        let gecos: String
        let home: String
        let shell: String
    }

    /// One `/etc/group` record (`name:password:gid:member,member`).
    struct Group: Equatable {
        let name: String
        let gid: UInt32
        let members: [String]
    }

    let users: [User]
    let groups: [Group]

    /// Parse the two files' text. Blank lines, `#` comments, and malformed
    /// records are skipped; the first record for a name or id wins.
    init(passwd: String? = nil, group: String? = nil) {
        var users: [User] = []
        for fields in Self.records(passwd) where fields.count >= 4 {
            guard !fields[0].isEmpty,
                  let uid = UInt32(fields[2]), let gid = UInt32(fields[3]) else { continue }
            users.append(User(name: fields[0], uid: uid, gid: gid,
                              gecos: fields.count > 4 ? fields[4] : "",
                              home: fields.count > 5 && !fields[5].isEmpty ? fields[5] : "/",
                              shell: fields.count > 6 && !fields[6].isEmpty ? fields[6] : "/bin/sh"))
        }
        var groups: [Group] = []
        for fields in Self.records(group) where fields.count >= 3 {
            guard !fields[0].isEmpty, let gid = UInt32(fields[2]) else { continue }
            let members = fields.count > 3
                ? fields[3].split(separator: ",").map(String.init)
                : []
            groups.append(Group(name: fields[0], gid: gid, members: members))
        }
        self.users = users
        self.groups = groups
    }

    private static func records(_ text: String?) -> [[String]] {
        guard let text else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let first = line.first(where: { $0 != " " && $0 != "\t" }), first != "#" else {
                return nil
            }
            return line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        }
    }

    // MARK: - Synthetic fallback

    /// The identity assumed for a uid that `/etc/passwd` does not list.
    static func syntheticUser(uid: UInt32) -> User {
        uid == 0
            ? User(name: "root", uid: 0, gid: 0, gecos: "root", home: "/root", shell: "/bin/sh")
            : User(name: "user\(uid)", uid: uid, gid: uid, gecos: "",
                   home: "/home/user\(uid)", shell: "/bin/sh")
    }

    /// The uid a synthetic name (`root`, `user1000`) stands for, if it is one.
    private static func syntheticUID(named name: String) -> UInt32? {
        if name == "root" { return 0 }
        guard name.hasPrefix("user") else { return nil }
        let digits = name.dropFirst(4)
        guard let uid = UInt32(digits), uid != 0, String(uid) == digits else { return nil }
        return uid
    }

    // MARK: - Users

    /// The listed record for `uid`, without the synthetic fallback.
    func listedUser(uid: UInt32) -> User? { users.first { $0.uid == uid } }

    /// The record for `uid`: the listed one, else the synthetic identity. Never
    /// fails, because every numeric uid is a usable credential.
    func user(uid: UInt32) -> User {
        listedUser(uid: uid) ?? Self.syntheticUser(uid: uid)
    }

    /// The record for a login name: a listed user, else a synthetic name
    /// (`root`, `userN`) whose uid is not claimed by a listed user.
    func user(named name: String) -> User? {
        if let listed = users.first(where: { $0.name == name }) { return listed }
        guard let uid = Self.syntheticUID(named: name), listedUser(uid: uid) == nil else {
            return nil
        }
        return Self.syntheticUser(uid: uid)
    }

    /// Resolve what a user typed for "a user" — a login name or a numeric uid
    /// (`su alice`, `su 1000`, `id 0`). Names take precedence over numbers.
    func resolveUser(_ specifier: String) -> User? {
        if let named = user(named: specifier) { return named }
        guard let uid = UInt32(specifier) else { return nil }
        return user(uid: uid)
    }

    /// The login name shown for `uid` (`whoami`, the `ls -l` owner column).
    func userName(uid: UInt32) -> String { user(uid: uid).name }

    // MARK: - Groups

    /// The listed record for `gid`, without the synthetic fallback.
    func listedGroup(gid: UInt32) -> Group? { groups.first { $0.gid == gid } }

    /// The record for a group name: a listed group, else the synthetic group of
    /// a synthetic user name whose gid no listed group claims.
    func group(named name: String) -> Group? {
        if let listed = groups.first(where: { $0.name == name }) { return listed }
        guard let gid = Self.syntheticUID(named: name), listedGroup(gid: gid) == nil else {
            return nil
        }
        return Group(name: name, gid: gid, members: [])
    }

    /// The name shown for `gid` (`id`, the `ls -l` group column): the listed
    /// group, else the synthetic `root` / `userN`.
    func groupName(gid: UInt32) -> String {
        listedGroup(gid: gid)?.name ?? Self.syntheticUser(uid: gid).name
    }

    /// Resolve a group name or numeric gid (`chgrp staff`, `chgrp 20`).
    func resolveGroupID(_ specifier: String) -> UInt32? {
        group(named: specifier)?.gid ?? UInt32(specifier)
    }

    /// Every group `user` belongs to: the primary gid first, then the listed
    /// groups naming the user as a member, ascending and without duplicates —
    /// what a login would pass to `setgroups`, and what `id NAME` prints.
    func groupIDs(for user: User) -> [UInt32] {
        let supplementary = Set(groups.filter { $0.members.contains(user.name) }.map(\.gid))
            .subtracting([user.gid])
        return [user.gid] + supplementary.sorted()
    }
}

extension ProcessContext {

    /// A snapshot of `/etc/passwd` and `/etc/group` as this process sees them
    /// (through its mount namespace). Missing or unreadable files simply yield
    /// the synthetic fallback. Reading here does not open descriptors or record
    /// syscalls: it models libc's name-service lookup, not file I/O by the caller.
    func userDatabase() -> UserDatabase {
        UserDatabase(passwd: nameServiceFile("/etc/passwd"), group: nameServiceFile("/etc/group"))
    }

    private func nameServiceFile(_ path: String) -> String? {
        guard let node = kernel.vfs.lookup(path, mounts: mountNS), node.kind == .file,
              node.deviceKind == nil else { return nil }
        return String(decoding: node.provider?() ?? node.fileContents, as: UTF8.self)
    }

    /// The login name of this process's effective uid (`whoami`).
    var userName: String { userDatabase().userName(uid: process.uid) }

    /// The uid that logged in on this process's session: the credentials of the
    /// session leader, which a later `su` in the same session does not change.
    /// `nil` once the session leader has exited (`logname` then has no answer).
    var loginUID: UInt32? {
        guard let leader = kernel.process(process.sessionID), leader.isLive else { return nil }
        return leader.uid
    }

    /// Become `user` (the credential half of `su`/`login`): install the user's
    /// supplementary groups, primary gid, and uid — in that order, because
    /// dropping the uid first would forfeit the right to change the others.
    ///
    /// With `login: true` (`su -`), also reset `HOME`, `USER`, `LOGNAME`, and
    /// `SHELL` from the record and change into the home directory when it
    /// exists; with `login: false` only the credentials change.
    ///
    /// - Returns: `false`, with credentials untouched, when the caller is neither
    ///   root nor already `user`.
    @discardableResult
    func switchUser(to user: UserDatabase.User,
                    database: UserDatabase? = nil,
                    login: Bool = false) -> Bool {
        guard process.uid == 0 || process.uid == user.uid else { return false }
        if process.uid == 0 {
            let database = database ?? userDatabase()
            process.supplementaryGroups = Set(database.groupIDs(for: user).dropFirst())
            process.gid = user.gid
            process.uid = user.uid
        }
        if login {
            setenv("HOME", user.home)
            setenv("USER", user.name)
            setenv("LOGNAME", user.name)
            setenv("SHELL", user.shell)
            _ = chdir(user.home)
        }
        return true
    }
}
