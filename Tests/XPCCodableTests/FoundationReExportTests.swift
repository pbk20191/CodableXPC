#if canImport(Darwin)
// Deliberately imports nothing but XPCCodable. Everything @XPCService generates
// names Foundation types, and a macro cannot introduce an import, so the module
// re-exports Foundation. Without that this file fails to build with "@objc
// attribute used without importing module 'Foundation'" pointing into code the
// author never wrote.
//
// Compiling is the assertion; there is nothing to run.
import XPCCodable

struct ReExportPayload: Codable {}

@XPCService
protocol ReExportService {
    func work(_ value: ReExportPayload) async throws -> ReExportPayload
}
#endif
