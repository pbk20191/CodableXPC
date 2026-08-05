import XCTest

// Guards the rule in Namespace.swift. Inside the `enum XPCCompat` body, an
// unqualified `Array`/`Dictionary` resolves to XPCCompat's nested type and
// compiles cleanly while producing the wrong type. Members must therefore be
// declared in file-scope extensions, never inside the enum body.
final class ShadowingLintTests: XCTestCase {

    func testNoMembersDeclaredInsideTheNamespaceBody() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XPCCompatTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/XPCCompat")

        let files = try FileManager.default
            .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        XCTAssertFalse(files.isEmpty, "no sources found at \(sourceDirectory.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Only Namespace.swift may open the enum body, and it must stay empty.
            if text.contains("public enum XPCCompat") {
                XCTAssertTrue(
                    text.contains("public enum XPCCompat {}"),
                    "\(file.lastPathComponent): the XPCCompat enum body must stay empty"
                )
            }
        }
    }
}
