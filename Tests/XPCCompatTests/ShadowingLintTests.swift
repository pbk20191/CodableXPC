import XCTest

/// Design test 11: no unqualified `Array(` / `Dictionary(` construction anywhere in
/// `Sources/XPCCompat`.
///
/// The hazard is name resolution. Anywhere lexically inside `enum XPCCompat` or an
/// `extension XPCCompat`, an unqualified `Array` resolves to `XPCCompat.Array` rather
/// than `Swift.Array` — and `Array()` *compiles cleanly while producing the wrong
/// type*. Only `Array(repeating:count:)` errors out. Silent-wrong is the dangerous
/// case, which is why this is a lint and not something the compiler catches.
///
/// Every type in this module is declared inside `extension XPCCompat { ... }`
/// (`Containers.swift`, `Endpoint.swift`, `SharedMemory.swift`, `LiteralValue.swift`),
/// so scanning only the enum body would miss almost all of the exposed scope. The scan
/// is whole-directory and recursive, so a future `Coder/` subdirectory is covered too.
final class ShadowingLintTests: XCTestCase {

    private static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // XPCCompatTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Sources/XPCCompat")

    /// Every `.swift` file under `Sources/XPCCompat`, recursively.
    private func swiftSources() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// Strips `//` line comments and `/* */` block comments, so a mention of
    /// `Array(` in prose or a doc comment is not a violation. Newlines are preserved
    /// so reported line numbers still match the file.
    private func strippingComments(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)

        var inLineComment = false
        var blockDepth = 0
        var inString = false
        var escaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let following: Character? = next < text.endIndex ? text[next] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    output.append(character)
                }
                index = next
                continue
            }
            if blockDepth > 0 {
                if character == "/", following == "*" {
                    blockDepth += 1
                    index = text.index(after: next)
                    continue
                }
                if character == "*", following == "/" {
                    blockDepth -= 1
                    index = text.index(after: next)
                    continue
                }
                if character == "\n" { output.append(character) }
                index = next
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                output.append(character)
                index = next
                continue
            }
            if character == "/", following == "/" {
                inLineComment = true
                index = text.index(after: next)
                continue
            }
            if character == "/", following == "*" {
                blockDepth = 1
                index = text.index(after: next)
                continue
            }
            if character == "\"" {
                inString = true
            }
            output.append(character)
            index = next
        }
        return output
    }

    /// Reports `Array(` / `Dictionary(` occurrences that carry no explicit module or
    /// namespace qualifier. `Swift.Array(`, `Swift.Dictionary(`, `XPCCompat.Array(`
    /// and `XPCCompat.Dictionary(` are all allowed, as is any longer identifier that
    /// merely ends in the name (`XPCDictionary(`, `sampleDictionary(`). A bare
    /// `Array(` is a violation. Type *references* — `as: XPCCompat.Array.self`,
    /// `-> [String]` — are not construction and are not matched.
    private func unqualifiedConstructions(in code: String) -> [(line: Int, text: String)] {
        var findings: [(line: Int, text: String)] = []

        for (offset, rawLine) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            for name in ["Array", "Dictionary"] {
                var searchRange = line.startIndex..<line.endIndex
                while let found = line.range(of: name + "(", range: searchRange) {
                    searchRange = found.upperBound..<line.endIndex

                    // A preceding `.` means it is qualified; a preceding identifier
                    // character means this is part of a longer name, not the bare type.
                    let qualifiedOrPartOfLongerName: Bool
                    if found.lowerBound > line.startIndex {
                        let previous = line[line.index(before: found.lowerBound)]
                        qualifiedOrPartOfLongerName =
                            previous == "." || previous.isLetter || previous.isNumber || previous == "_"
                    } else {
                        qualifiedOrPartOfLongerName = false
                    }

                    if !qualifiedOrPartOfLongerName {
                        findings.append((line: offset + 1, text: line.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        }
        return findings
    }

    func testNoUnqualifiedArrayOrDictionaryConstruction() throws {
        let files = try swiftSources()
        XCTAssertFalse(files.isEmpty, "no sources found at \(Self.sourceDirectory.path)")

        var violations: [String] = []
        for file in files {
            let code = strippingComments(try String(contentsOf: file, encoding: .utf8))
            for finding in unqualifiedConstructions(in: code) {
                violations.append("\(file.lastPathComponent):\(finding.line): \(finding.text)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Unqualified Array(/Dictionary( construction inside Sources/XPCCompat. \
            Lexically inside `enum XPCCompat` and every `extension XPCCompat` these \
            resolve to XPCCompat's nested types and compile silently wrong. Spell them \
            `Swift.Array(` / `Swift.Dictionary(` or `XPCCompat.Array(` / \
            `XPCCompat.Dictionary(`.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    /// The narrower rule the module is also written to: nothing but the nested type
    /// declarations lives directly in the enum body, which keeps the very worst of the
    /// shadowing scope empty.
    func testNamespaceEnumBodyStaysEmpty() throws {
        let files = try swiftSources()
        XCTAssertFalse(files.isEmpty, "no sources found at \(Self.sourceDirectory.path)")

        var sawDeclaration = false
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("public enum XPCCompat") else { continue }
            sawDeclaration = true
            XCTAssertTrue(
                text.contains("public enum XPCCompat {}"),
                "\(file.lastPathComponent): the XPCCompat enum body must stay empty"
            )
        }
        XCTAssertTrue(sawDeclaration, "the XPCCompat namespace enum declaration was not found")
    }
}
