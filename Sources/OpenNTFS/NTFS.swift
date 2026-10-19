import Foundation

struct Volume: Identifiable, Equatable {
    let id: String              // e.g. "disk4s1"
    var name: String
    var wholeDisk: String
    var size: Int64
    var free: Int64?
    var mountPoint: String?
    var writable: Bool
    var dev: String { "/dev/\(id)" }
}

struct MountEntry: Equatable {
    let mountPoint: String
    let type: String
    let writable: Bool
}

struct NTFSError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw NTFSError(text) }
        return text
    }

    /// Runs a shell line as root behind the standard macOS admin password prompt.
    // ponytail: osascript admin prompt, swap for an SMJobBless/SMAppService privileged helper if prompts get annoying
    @discardableResult
    static func admin(_ line: String) throws -> String {
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        do {
            return try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        } catch let e as NTFSError {
            // osascript prefixes errors with "execution error: ... (code)"; keep the useful part.
            let msg = e.errorDescription ?? ""
            let clean = msg.components(separatedBy: "execution error: ").last ?? msg
            throw NTFSError(clean.replacingOccurrences(of: #"\s*\(-?\d+\)$"#, with: "", options: .regularExpression))
        }
    }

    /// Single-quotes a string for /bin/sh.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum Tools {
    static let dirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
    static func path(_ name: String) -> String? {
        dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func require(_ name: String) throws -> String {
        guard let p = path(name) else { throw NTFSError("\(name) is not installed. Click “Install ntfs-3g” in the menu.") }
        return p
    }
    static let installCommand = "brew install --cask macfuse && brew install gromgit/fuse/ntfs-3g-mac"
}

enum Disks {
    /// Parses `/sbin/mount` output into device id -> mount info.
    static func parseMounts(_ text: String) -> [String: MountEntry] {
        var result: [String: MountEntry] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("/dev/"), line.hasSuffix(")"),
                  let on = line.range(of: " on "),
                  let paren = line.range(of: " (", options: .backwards), paren.lowerBound > on.upperBound
            else { continue }
            let dev = String(line[line.index(line.startIndex, offsetBy: 5)..<on.lowerBound])
            let opts = line[paren.upperBound..<line.index(before: line.endIndex)]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            result[dev] = MountEntry(mountPoint: String(line[on.upperBound..<paren.lowerBound]),
                                     type: opts.first ?? "",
                                     writable: !opts.contains("read-only"))
        }
        return result
    }

    static func diskutil(_ verb: String, _ id: String? = nil) -> [String: Any] {
        guard let text = try? Shell.run("/usr/sbin/diskutil", [verb, "-plist"] + (id.map { [$0] } ?? [])),
              let obj = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        else { return [:] }
        return obj as? [String: Any] ?? [:]
    }

    static func scan() -> [Volume] {
        let mounts = parseMounts((try? Shell.run("/sbin/mount", [])) ?? "")
        let disks = diskutil("list")["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        let parts = disks.flatMap { d in (d["Partitions"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? [d] }

        return parts.compactMap { p -> Volume? in
            // MBR NTFS = Windows_NTFS, GPT NTFS = Microsoft Basic Data (shared with exFAT/FAT, so probe below).
            guard let id = p["DeviceIdentifier"] as? String,
                  ["Windows_NTFS", "Microsoft Basic Data"].contains(p["Content"] as? String ?? "")
            else { return nil }
            let info = diskutil("info", id)
            let fs = (info["FilesystemType"] as? String ?? "").lowercased()
            let m = mounts[id]
            let fuse = m.map { $0.type.contains("fuse") || $0.type.contains("ntfs") } ?? false
            guard fs.contains("ntfs") || fuse else { return nil }

            let name = [info["VolumeName"], p["VolumeName"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? id
            var free: Int64?
            if let mp = m?.mountPoint, let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mp) {
                free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            }
            return Volume(id: id,
                          name: name.replacingOccurrences(of: "/", with: "-"),
                          wholeDisk: info["ParentWholeDisk"] as? String ?? id,
                          size: (info["Size"] as? NSNumber ?? p["Size"] as? NSNumber)?.int64Value ?? 0,
                          free: free,
                          mountPoint: m?.mountPoint,
                          writable: m?.writable ?? false)
        }
    }
}

enum Ops {
    /// Shell snippet that mounts `v` read/write with ntfs-3g, falling back to the native read-only mount on failure.
    static func mountLine(_ v: Volume, ntfs3g: String) -> String {
        let mp = Shell.q("/Volumes/\(v.name)")
        return """
        mkdir -p \(mp) && \(ntfs3g) \(v.dev) \(mp) -o local -o allow_other -o auto_xattr -o auto_cache \
        -o uid=\(getuid()) -o gid=\(getgid()) -o volname=\(Shell.q(v.name)) \
        || { rmdir \(mp) 2>/dev/null; /usr/sbin/diskutil mount \(v.dev) >/dev/null; exit 1; }
        """
    }

    static func unmountLine(_ v: Volume) -> String {
        "/usr/sbin/diskutil unmount \(v.dev) >/dev/null 2>&1 || /sbin/umount -f \(v.dev) 2>/dev/null; true"
    }

    static func mountRW(_ v: Volume) throws {
        let ntfs3g = try Tools.require("ntfs-3g")
        try Shell.admin(unmountLine(v) + "; " + mountLine(v, ntfs3g: ntfs3g))
    }

    static func eject(_ v: Volume) throws {
        // ntfs-3g mounts are owned by root, so fall back to admin if a plain eject is refused.
        if (try? Shell.run("/usr/sbin/diskutil", ["eject", v.wholeDisk])) == nil {
            try Shell.admin("/usr/sbin/diskutil unmountDisk force \(v.wholeDisk) && /usr/sbin/diskutil eject \(v.wholeDisk)")
        }
    }

    /// Clears the dirty flag / journal so Windows-touched volumes mount again.
    static func repair(_ v: Volume) throws {
        let fix = try Tools.require("ntfsfix"), ntfs3g = try Tools.require("ntfs-3g")
        try Shell.admin(unmountLine(v) + "; \(fix) -d \(v.dev) && " + mountLine(v, ntfs3g: ntfs3g))
    }

    static func rename(_ v: Volume, to name: String) throws {
        let label = try Tools.require("ntfslabel"), ntfs3g = try Tools.require("ntfs-3g")
        var renamed = v
        renamed.name = name.replacingOccurrences(of: "/", with: "-")
        try Shell.admin(unmountLine(v) + "; \(label) \(v.dev) \(Shell.q(name)) && " + mountLine(renamed, ntfs3g: ntfs3g))
    }

    static func format(_ v: Volume, label: String) throws {
        let mkntfs = try Tools.require("mkntfs"), ntfs3g = try Tools.require("ntfs-3g")
        var fresh = v
        fresh.name = label.replacingOccurrences(of: "/", with: "-")
        try Shell.admin(unmountLine(v) + "; \(mkntfs) -f -F -L \(Shell.q(label)) \(v.dev) >/dev/null && " + mountLine(fresh, ntfs3g: ntfs3g))
    }
}
