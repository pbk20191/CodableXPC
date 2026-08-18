import XCTest
import XPC
import Distributed
import CodableXPC
@testable import XPCActors

// Every fixture in this file was written from
// `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md` -- sections
// *Invocation coding*, *SwiftType*, *protocolStub*, *How protocolStub is recorded, and
// why genericSubsitutions is always empty*, *basePriority is derived, not passed*, and
// *Request* -- not from what the encoder happened to produce.
//
// The mangled names below are spelled out rather than looked up, and every one of them
// is independently checkable with `swift demangle`:
//
//     $sSS  -> Swift.String
//     $sSi  -> Swift.Int
//     $sScE -> Swift.CancellationError
//
// so a regression in `TypeName` cannot quietly move the fixture with the implementation.

/// `internal`, not `private`. A `private` type's mangled name carries a process-address
/// discriminator and does not resolve -- which is precisely what a distributed signature
/// may not contain, and what `testAnUnresolvableReturnTypeThrows` pins.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct Payload: Codable, Equatable { let n: Int }

/// A distributed protocol, which is the only way a `_DistributedActorStub` conformer
/// comes into existence: `@Resolvable` generates `$Greeter`, a `distributed actor`
/// conforming to `Greeter` **and** to `Distributed._DistributedActorStub`. That stub is
/// what a call through a protocol -- rather than through a concrete actor type -- is
/// targeted at, and what `recordGenericSubstitution` is expected to divert into
/// `protocolStub`.
///
/// The actor system parameter only has to name *some* system for the stub type to be
/// concrete; `LocalTestingDistributedActorSystem` is the stdlib's own and nothing in
/// these tests ever instantiates it.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
@Resolvable
protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
    distributed func greet(name: String) -> String
}

/// A second, distinct stub type -- `protocolStub` holds at most one, and the second one
/// has to be rejected rather than overwrite the first.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
@Resolvable
protocol Counter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
    distributed func count() -> Int
}

@available(macOS 26, *)
final class InvocationEncoderTests: XCTestCase {

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        normalizedDescription(try XPCEncoder().encode(value))
    }

    // MARK: - protocolStub comes out of recordGenericSubstitution
    //
    // `DistributedTargetInvocationEncoder` has no `recordProtocolStub` and Apple did not
    // add one -- `InvocationEncoder`'s only witnesses are the four `record*` methods plus
    // `doneRecording`. Both of Apple's error strings resolve to `recordGenericSubstitution`
    // (`0x2ad4ff6e4`), which branches on the recorded type before wrapping it in a
    // `SwiftType`.

    func testAStubIsRecordedAsTheProtocolStubAndNotAsAGenericSubstitution() throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else {
            throw XCTSkip("_DistributedActorStub is macOS 15+")
        }
        var encoder = InvocationEncoder()
        try encoder.recordGenericSubstitution($Greeter<LocalTestingDistributedActorSystem>.self)
        try encoder.doneRecording()

        let stub = try XCTUnwrap(encoder.protocolStub)
        XCTAssertTrue(stub.type == $Greeter<LocalTestingDistributedActorSystem>.self,
                      "the recorded name must resolve back to the stub type")
        XCTAssertTrue(encoder.genericSubsitutions.isEmpty)

        // ...and it reaches the wire under `protocolStub`, as a bare string, with
        // `genericSubsitutions` still present and still empty.
        let object = try XPCEncoder().encode(encoder.makeInvocationBody())
        let encodedStub = try XCTUnwrap(xpc_dictionary_get_value(object, "protocolStub"))
        XCTAssertEqual(xpc_get_type(encodedStub), XPC_TYPE_STRING)
        XCTAssertEqual(String(cString: xpc_string_get_string_ptr(encodedStub)!),
                       stub.mangledTypeName)
        let generics = try XCTUnwrap(xpc_dictionary_get_value(object, "genericSubsitutions"))
        XCTAssertEqual(xpc_get_type(generics), XPC_TYPE_ARRAY)
        XCTAssertEqual(xpc_array_get_count(generics), 0)
    }

    /// Apple raises `"Encoding second _DistributedActorStub "`; the field holds one.
    func testASecondStubIsRejected() throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else {
            throw XCTSkip("_DistributedActorStub is macOS 15+")
        }
        var encoder = InvocationEncoder()
        try encoder.recordGenericSubstitution($Greeter<LocalTestingDistributedActorSystem>.self)
        XCTAssertThrowsError(
            try encoder.recordGenericSubstitution(
                $Counter<LocalTestingDistributedActorSystem>.self)
        ) { error in
            let message = (error as? DistributedActorCodingError)?.message
            XCTAssertNotNil(message, "expected a DistributedActorCodingError, got \(error)")
            XCTAssertTrue(message?.contains("second") == true, message ?? "")
            XCTAssertTrue(message?.contains("_DistributedActorStub") == true, message ?? "")
        }
        // The first one survives the rejection.
        XCTAssertEqual(encoder.protocolStub,
                       SwiftType($Greeter<LocalTestingDistributedActorSystem>.self))
    }

    /// Recording the *same* stub twice is still a second stub -- there is one slot, not
    /// one slot per type.
    func testTheSameStubRecordedTwiceIsAlsoASecondStub() throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else {
            throw XCTSkip("_DistributedActorStub is macOS 15+")
        }
        var encoder = InvocationEncoder()
        try encoder.recordGenericSubstitution($Greeter<LocalTestingDistributedActorSystem>.self)
        XCTAssertThrowsError(
            try encoder.recordGenericSubstitution(
                $Greeter<LocalTestingDistributedActorSystem>.self))
    }

    // MARK: - a real generic substitution is refused, loudly and early
    //
    // Apple records it and then *traps* at encode time -- `encode(to:)` (`0x2ad4ffb38`)
    // ends with "Bug in XPCDistributed: Found generic substitutions during encoding."
    // followed by a `BRK`. A non-empty `genericSubsitutions` is therefore unrepresentable
    // either way; we deviate on timing and failure mode only, throwing here so the
    // failure lands at the call site that caused it.

    func testANonStubGenericSubstitutionThrowsAndNamesTheType() throws {
        var encoder = InvocationEncoder()
        XCTAssertThrowsError(try encoder.recordGenericSubstitution(Int.self)) { error in
            let message = (error as? DistributedActorCodingError)?.message
            XCTAssertNotNil(message, "expected a DistributedActorCodingError, got \(error)")
            XCTAssertTrue(message?.contains("Int") == true,
                          "the message must name the offending type: \(message ?? "")")
        }
        XCTAssertTrue(encoder.genericSubsitutions.isEmpty)
        XCTAssertNil(encoder.protocolStub)
    }

    /// The key is not optional and never conditional: `[]` is a value, and its absence
    /// would be a different message.
    func testGenericSubsitutionsIsAlwaysPresentAndAlwaysEmpty() throws {
        var encoder = InvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: nil, name: "n", value: 1))
        try encoder.doneRecording()
        XCTAssertTrue(encoder.genericSubsitutions.isEmpty)

        let object = try XPCEncoder().encode(encoder.makeInvocationBody())
        let generics = try XCTUnwrap(xpc_dictionary_get_value(object, "genericSubsitutions"))
        XCTAssertEqual(xpc_get_type(generics), XPC_TYPE_ARRAY)
        XCTAssertEqual(xpc_array_get_count(generics), 0)
        // Apple's typo is the wire key; the corrected spelling must not appear.
        XCTAssertNil(xpc_dictionary_get_value(object, "genericSubstitutions"))
    }

    // MARK: - errorType degrades, returnType does not

    func testErrorTypeSurvivesAsAMangledName() throws {
        var encoder = InvocationEncoder()
        try encoder.recordErrorType(CancellationError.self)
        try encoder.doneRecording()
        XCTAssertEqual(encoder.errorType, SwiftType(mangledTypeName: "ScE"))
        XCTAssertEqual(try encoded(encoder.makeInvocationBody()),
                       "{arguments=[],errorType=string(ScE),genericSubsitutions=[]}")
    }

    /// `errorType`'s **presence** is what tells the receiver the target can throw, so the
    /// key has to be there whatever the type is. That is the one place a name a peer
    /// cannot resolve beats no name at all.
    ///
    /// The degraded arm itself could not be provoked: on this toolchain
    /// `_mangledTypeName` returns a name for every `Error`-conforming type that can be
    /// constructed. So what is pinned here is the invariant the arm exists to protect --
    /// the key is present for every error type we can build -- plus, below, the reason
    /// the arm is quarantined to this one field.
    func testTheErrorTypeKeyIsPresentForEveryErrorTypeWeCanBuild() throws {
        struct LocalBoom: Error {}
        enum NestedBoom: Error { case boom }
        struct GenericBoom<T>: Error {}
        final class ClassBoom: NSObject, Error {}

        func check<E: Error>(_ type: E.Type) throws {
            var encoder = InvocationEncoder()
            try encoder.recordErrorType(type)
            try encoder.doneRecording()
            XCTAssertNotNil(encoder.errorType, "\(type)")
            let object = try XPCEncoder().encode(encoder.makeInvocationBody())
            XCTAssertNotNil(xpc_dictionary_get_value(object, "errorType"), "\(type)")
        }

        try check(LocalBoom.self)
        try check(NestedBoom.self)
        try check(GenericBoom<LocalBoom>.self)
        try check(ClassBoom.self)
        try check(CancellationError.self)
        try check(DecodingError.self)
        try check(NSError.self)
    }

    /// Why the degradation is confined to `errorType`: the fallback name is a display
    /// string, and a display string is exactly what no peer can resolve.
    func testTheDegradedSpellingIsNotInteroperable() {
        struct Boom: Error {}
        XCTAssertNil(SwiftType(mangledTypeName: "\(Boom.self)").type)
        XCTAssertEqual("\(Boom.self)", "Boom")
    }

    func testReturnTypeSurvivesAsAMangledName() throws {
        var encoder = InvocationEncoder()
        try encoder.recordReturnType(String.self)
        try encoder.doneRecording()
        XCTAssertEqual(encoder.returnType, SwiftType(mangledTypeName: "SS"))
        XCTAssertEqual(try encoded(encoder.makeInvocationBody()),
                       "{arguments=[],genericSubsitutions=[],returnType=string(SS)}")
    }

    /// Every return type a peer could actually resolve records as a resolvable name.
    ///
    /// Note what this asserts and what it must not: `recorded.type == type` reads back
    /// through `TypeName`, so it would be worthless if `TypeName.mangled(for:)` seeded
    /// the reverse map with its own unverified guess. It used to, and this test passed
    /// for `LocalResult` because of it. The seeding is gone; only a real `_typeByName`
    /// populates the reverse direction now, so this assertion is answered by the runtime.
    func testAResolvableReturnTypeRecordsAResolvableName() throws {
        func check<R: Codable>(_ type: R.Type) throws {
            var encoder = InvocationEncoder()
            try encoder.recordReturnType(type)
            try encoder.doneRecording()
            let recorded = try XCTUnwrap(encoder.returnType, "\(type)")
            XCTAssertTrue(recorded.type == type,
                          "\(type) recorded as \(recorded.mangledTypeName), which does not resolve")
        }

        try check(String.self)
        try check(Int.self)
        try check([Payload].self)
        try check(Payload?.self)
    }

    /// The throwing arm, now reachable.
    ///
    /// A function-local type -- and equally any `private` or `fileprivate` type -- mangles
    /// to a name containing a `$<process address>yXZ` discriminator that `_typeByName`
    /// cannot resolve. `_mangledTypeName` still returns non-nil for it, so a nil check
    /// alone would let it through; `SwiftType(_:)` checks the round trip instead.
    ///
    /// This is not an exotic case. It means a distributed func's signature may not use a
    /// `fileprivate` type, which is a real constraint on callers and fails loudly here
    /// rather than as an unresolvable type in the peer's process.
    func testAnUnresolvableReturnTypeThrows() throws {
        struct LocalResult: Codable {}
        var encoder = InvocationEncoder()
        XCTAssertThrowsError(try encoder.recordReturnType(LocalResult.self)) { error in
            XCTAssertTrue("\(error)".contains("LocalResult"),
                          "the message must name the type: \(error)")
        }
    }

    /// And the same construction is what makes `errorType`'s degradation reachable: the
    /// key stays present, because its presence is what tells the receiver the target can
    /// throw, but the recorded name is knowingly not interoperable.
    func testAnUnresolvableErrorTypeStillLeavesTheKeyPresent() throws {
        struct LocalError: Error, Codable {}
        var encoder = InvocationEncoder()
        try encoder.recordErrorType(LocalError.self)
        try encoder.doneRecording()
        let recorded = try XCTUnwrap(encoder.makeInvocationBody().errorType,
                                     "the key must survive -- its presence is the signal")
        XCTAssertNil(recorded.type, "the degraded name is not expected to resolve")
    }

    func testNoErrorTypeMeansTheTargetDoesNotThrow() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        XCTAssertNil(encoder.makeInvocationBody().errorType)
    }

    // MARK: - arguments

    /// Labels are discarded deliberately: the receiver knows them statically, so putting
    /// them on the wire would be pure overhead.
    func testArgumentLabelsAreDiscarded() throws {
        var encoder = InvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "greeting", name: "g", value: "hi"))
        try encoder.doneRecording()
        let rendered = try encoded(encoder.makeInvocationBody())
        XCTAssertFalse(rendered.contains("greeting"))
        XCTAssertTrue(rendered.contains("arguments=[string(hi)]"))
    }

    func testArgumentOrderIsPreserved() throws {
        var encoder = InvocationEncoder()
        for n in 0..<5 {
            try encoder.recordArgument(RemoteCallArgument(label: nil, name: "", value: n))
        }
        try encoder.doneRecording()
        XCTAssertTrue(try encoded(encoder.makeInvocationBody()).contains(
            "arguments=[int64(0),int64(1),int64(2),int64(3),int64(4)]"))
    }

    /// Two calls must not share accumulated state. `makeInvocationEncoder()` returns a
    /// fresh value per invocation, and a struct is what makes that cheap -- but only if
    /// nothing static leaks between them.
    func testEncodersDoNotShareState() throws {
        var first = InvocationEncoder()
        try first.recordArgument(RemoteCallArgument(label: nil, name: "", value: 1))
        try first.recordErrorType(CancellationError.self)
        try first.doneRecording()

        var second = InvocationEncoder()
        try second.doneRecording()
        XCTAssertTrue(second.arguments.isEmpty)
        XCTAssertNil(second.errorType)
        XCTAssertEqual(first.arguments.count, 1)
    }

    // MARK: - basePriority is derived, not passed
    //
    // Apple's initializer is `init(id:targetedSharedActor:remoteCallTarget:invocation:)`
    // -- no `basePriority` parameter, and `basePriority` has a getter and no setter, so
    // the request computes it. `Task.basePriority` is the source: same name, same
    // `TaskPriority?` type, and it is what the escalation notifications exist to raise.

    func testBasePriorityIsTheCallingTasksBasePriority() async throws {
        let request = await Task(priority: .high) { () -> RemoteInvocationRequest in
            var encoder = InvocationEncoder()
            try? encoder.doneRecording()
            return encoder.makeRequest(id: ID64(rawValue: 1),
                                       targetedSharedActor: .dynamic(ID64(rawValue: 1)),
                                       remoteCallTarget: RemoteCallTarget("t"))
        }.value
        XCTAssertEqual(request.basePriority, .high)
        XCTAssertEqual(request.basePriority?.rawValue, 25)

        let object = try XPCEncoder().encode(request)
        let priority = try XCTUnwrap(xpc_dictionary_get_value(object, "basePriority"))
        XCTAssertEqual(xpc_get_type(priority), XPC_TYPE_UINT64)
        XCTAssertEqual(xpc_uint64_get_value(priority), 25)
    }

    func testBasePriorityFollowsWhicheverTaskMakesTheRequest() async throws {
        for (priority, raw) in [(TaskPriority.high, UInt8(25)), (.medium, 21),
                                (.low, 17), (.background, 9)] {
            let request = await Task(priority: priority) { () -> RemoteInvocationRequest in
                InvocationEncoder().makeRequest(
                    id: ID64(rawValue: 1),
                    targetedSharedActor: .dynamic(ID64(rawValue: 1)),
                    remoteCallTarget: RemoteCallTarget("t"))
            }.value
            XCTAssertEqual(request.basePriority?.rawValue, raw)
        }
    }

    /// Outside any task there is no base priority to derive, and a nil optional means
    /// the key is not written -- never a null.
    func testNoTaskMeansNoBasePriorityKey() throws {
        XCTAssertNil(Task.basePriority, "this test only means anything off a task")
        let request = InvocationEncoder().makeRequest(
            id: ID64(rawValue: 1),
            targetedSharedActor: .dynamic(ID64(rawValue: 1)),
            remoteCallTarget: RemoteCallTarget("t"))
        XCTAssertNil(request.basePriority)
        XCTAssertNil(xpc_dictionary_get_value(try XPCEncoder().encode(request), "basePriority"))
    }

    // MARK: - end to end
    //
    // One realistic invocation -- `func greet(name: String) throws -> String`, called on
    // an actor exported under a name -- recorded, turned into a request, and pinned
    // whole. Key order in the rendering is `normalizedDescription`'s sort, not the wire's;
    // what is pinned is the set of keys, the nesting, and every leaf's xpc type.

    func testAWholeRecordedRequestIsPinned() async throws {
        let request = await Task(priority: .high) { () -> RemoteInvocationRequest in
            var encoder = InvocationEncoder()
            try? encoder.recordArgument(
                RemoteCallArgument(label: "name", name: "name", value: "hi"))
            try? encoder.recordArgument(
                RemoteCallArgument(label: nil, name: "n", value: 7 as Int))
            try? encoder.recordErrorType(CancellationError.self)
            try? encoder.recordReturnType(String.self)
            try? encoder.doneRecording()
            return encoder.makeRequest(
                id: ID64(rawValue: 42),
                targetedSharedActor: .exportedRawValue("primary"),
                remoteCallTarget: RemoteCallTarget("$s4Test7GreeterC5greet4nameSSSS_tYaKFTE"))
        }.value

        XCTAssertEqual(
            try encoded(request),
            "{basePriority=uint64(25),"
            + "contents=dict{arguments=[string(hi),int64(7)],"
            + "errorType=string(ScE),"
            + "genericSubsitutions=[],"
            + "returnType=string(SS)},"
            + "id=uint64(42),"
            + "remoteCallIdentifier=string($s4Test7GreeterC5greet4nameSSSS_tYaKFTE),"
            + "targetedSharedActor=[uint64(1),string(primary)]}")

        // `protocolStub` is nil here, and a nil optional omits its key entirely.
        let object = try XPCEncoder().encode(request)
        let contents = try XCTUnwrap(xpc_dictionary_get_value(object, "contents"))
        XCTAssertNil(xpc_dictionary_get_value(contents, "protocolStub"))
    }
}
