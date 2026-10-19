import XCTest
@testable import OpenNTFS

final class ParseTests: XCTestCase {
    func testParseMounts() {
        let out = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        devfs on /dev (devfs, local, nobrowse)
        /dev/disk4s1 on /Volumes/My (Win) Drive (ntfs, local, nodev, nosuid, read-only, noowners)
        /dev/disk5s2 on /Volumes/Data (macfuse, local, synchronous)
        """
        let m = Disks.parseMounts(out)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m["disk4s1"], MountEntry(mountPoint: "/Volumes/My (Win) Drive", type: "ntfs", writable: false))
        XCTAssertEqual(m["disk5s2"], MountEntry(mountPoint: "/Volumes/Data", type: "macfuse", writable: true))
    }

    func testShellQuote() {
        XCTAssertEqual(Shell.q("it's"), #"'it'\''s'"#)
    }
}
