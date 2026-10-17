import Foundation

/// The sudoers rule the helper keeps for each user at
/// /etc/sudoers.d/ember-<uid>: only the commands that give sleep back or
/// switch Low Power Mode, so backstop.sh can still restore the Mac when the
/// app is gone. Turning sleep off is the helper's job and has no line here.
/// One file per user, so a second account approving Ember on the same Mac
/// never takes the first one's lines away; named by uid because sudo skips
/// files whose name contains a dot, which a user name may.
public enum RestoreRule {
    public static let directory = "/etc/sudoers.d"
    /// The file install.sh writes (four lines, one user).
    public static let legacyName = "ember"

    public static func fileName(forUID uid: uid_t) -> String { "ember-\(uid)" }

    /// The three commands, as backstop.sh and the app run them.
    public static let commands: [[String]] = [
        ["-a", "disablesleep", "0"],
        ["-b", "lowpowermode", "1"],
        ["-b", "lowpowermode", "0"],
    ]

    /// The file's whole text for `user`, who must pass `isValidUserName`.
    public static func text(user: String) -> String {
        precondition(isValidUserName(user), "not a user name sudoers can hold as is")
        var lines = [
            "# Written by Ember's helper. The pmset commands that turn sleep back on or",
            "# switch Low Power Mode, so Ember's recovery agent can restore this Mac",
            "# without a password. Turning sleep off goes through the helper only.",
        ]
        for args in commands {
            lines.append("\(user) ALL=(root) NOPASSWD: /usr/bin/pmset \(args.joined(separator: " "))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A short POSIX account name: nothing sudoers would read as syntax.
    public static func isValidUserName(_ name: String) -> Bool {
        name.range(of: #"^[a-z_][a-z0-9_.-]{0,31}$"#, options: .regularExpression) != nil
    }

    /// The account name of `uid`, from the password database.
    public static func userName(forUID uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}
