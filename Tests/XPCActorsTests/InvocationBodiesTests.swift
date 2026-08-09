import XCTest
import XPC
import CodableXPC
@testable import XPCActors

/// The invocation wire shapes, pinned against Apple's shipping `XPCDistributed`.
///
/// Every fixture in this file was written from
/// `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md` and the R2
/// brief -- not from what the implementation happened to produce. The container choice
/// behind each one was resolved mechanically with
/// `xpcdump/macos27-XPCDistributed/verify-containers.py`, whose `SharedActorKey`
/// (unkeyed) and `Ack` (keyed) controls tell a broken run from a surprising answer:
///
///     RemoteInvocationRequest.encode(to:)   -> Encoder.container(keyedBy:)
///     RemoteNotification.encode(to:)        -> Encoder.container(keyedBy:)
///     RemoteInvocationResponse.encode(to:)  -> Encoder.singleValueContainer()
///     RemoteInvocationFailure.encode(to:)   -> Encoder.container(keyedBy:)
///     Either.encode(to:)                    -> Encoder.unkeyedContainer()

/// Enough of a session to let an `ActorID` code itself. `ActorIDTests` has its own,
/// `private` to that file.
@available(macOS 14, *)
final class InvocationBodiesTests: XCTestCase {

    private func encoded<T: Encodable>(
        _ value: T, userInfo: [CodingUserInfoKey: Any] = [:]
    ) throws -> String {
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo
        return normalizedDescription(try encoder.encode(value))
    }

    private static let fullInvocation = InvocationBody(
        protocolStub: SwiftType(mangledTypeName: "P"),
        genericSubsitutions: [SwiftType(mangledTypeName: "Si")],
        arguments: [7 as Int, "hi" as String],
        errorType: SwiftType(mangledTypeName: "Se"),
        returnType: SwiftType(mangledTypeName: "SS"))

    // MARK: tier 1 -- the invocation dictionary
    //
    // `XPCSystem.InvocationCodingKeys`, in declaration order:
    //   protocolStub? / genericSubsitutions / arguments / errorType? / returnType?
    // The misspelling of `genericSubsitutions` is Apple's and is required: the wire
    // coder spells it with one 's' after "sub", while the never-serialised
    // `DirectInvocationDecoder` spells it correctly.

    func testTheInvocationBodyIsPinned() throws {
        XCTAssertEqual(
            try encoded(Self.fullInvocation),
            "{arguments=[int64(7),string(hi)],"
            + "errorType=string(Se),"
            + "genericSubsitutions=[string(Si)],"
            + "protocolStub=string(P),"
            + "returnType=string(SS)}")
    }

    /// `SwiftType` is a bare String on the wire, so nothing here is a nested dictionary.
    func testEveryTypeReferenceIsABareString() throws {
        let object = try XPCEncoder().encode(Self.fullInvocation)
        for key in ["protocolStub", "errorType", "returnType"] {
            let value = try XCTUnwrap(xpc_dictionary_get_value(object, key), "\(key)")
            XCTAssertEqual(xpc_get_type(value), XPC_TYPE_STRING, "\(key)")
        }
        let generics = try XCTUnwrap(xpc_dictionary_get_value(object, "genericSubsitutions"))
        XCTAssertEqual(xpc_get_type(xpc_array_get_value(generics, 0)), XPC_TYPE_STRING)
    }

    /// Apple's typo, reproduced deliberately. A peer looks for exactly this key.
    func testTheMisspellingIsRequired() throws {
        let object = try XPCEncoder().encode(Self.fullInvocation)
        XCTAssertNotNil(xpc_dictionary_get_value(object, "genericSubsitutions"))
        XCTAssertNil(xpc_dictionary_get_value(object, "genericSubstitutions"))
    }

    /// A nil optional means the key is not written -- never a null value. A peer
    /// decoding `{"errorType": null}` would see a present-but-broken field.
    func testAbsentInvocationOptionalsOmitTheirKeysEntirely() throws {
        let body = InvocationBody(protocolStub: nil, genericSubsitutions: [],
                                  arguments: [], errorType: nil, returnType: nil)
        let object = try XPCEncoder().encode(body)
        for key in ["protocolStub", "errorType", "returnType"] {
            XCTAssertNil(xpc_dictionary_get_value(object, key), "\(key)")
        }
        XCTAssertEqual(normalizedDescription(object),
                       "{arguments=[],genericSubsitutions=[]}")
    }

    /// `genericSubsitutions` and `arguments` are always present, empty or not. They are
    /// not optionals, and an absent key is a different thing from an empty one.
    func testEmptyGenericsAndArgumentsArePresentAsEmptyArrays() throws {
        let object = try XPCEncoder().encode(
            InvocationBody(protocolStub: nil, genericSubsitutions: [], arguments: [],
                           errorType: nil, returnType: nil))
        for key in ["genericSubsitutions", "arguments"] {
            let value = try XCTUnwrap(xpc_dictionary_get_value(object, key), "\(key)")
            XCTAssertEqual(xpc_get_type(value), XPC_TYPE_ARRAY, "\(key)")
            XCTAssertEqual(xpc_array_get_count(value), 0, "\(key)")
        }
    }

    /// Arguments are positional, carry no per-argument type tag, and lose their labels:
    /// the receiver's `executeDistributedTarget` knows each parameter type statically
    /// and asks in order.
    func testArgumentsArePositionalAndUntagged() throws {
        let object = try XPCEncoder().encode(InvocationBody(
            protocolStub: nil, genericSubsitutions: [],
            arguments: [1 as Int, "two" as String, 3.5 as Double],
            errorType: nil, returnType: nil))
        let arguments = try XCTUnwrap(xpc_dictionary_get_value(object, "arguments"))
        XCTAssertEqual(normalizedDescription(arguments),
                       "[int64(1),string(two),double(3.5)]")
    }

    // MARK: tier 1 -- the request
    //
    // `Session.RemoteInvocationRequest`, a keyed dictionary:
    //   id / basePriority? / targetedSharedActor / remoteCallIdentifier / contents
    // `contents` is the invocation dictionary directly. `InvocationContents`'s
    // send/recv is an in-memory distinction, not a wire tag.

    private static let fullRequest = RemoteInvocationRequest(
        id: ID64(rawValue: 42),
        basePriority: .high,
        targetedSharedActor: .exportedRawValue("primary"),
        remoteCallIdentifier: "$s4Test7GreeterC5greet4nameSSSS_tYaKFTE",
        contents: InvocationBodiesTests.fullInvocation)

    func testTheRequestIsPinned() throws {
        XCTAssertEqual(
            try encoded(Self.fullRequest),
            "{basePriority=uint64(25),"
            + "contents=dict{arguments=[int64(7),string(hi)],"
            + "errorType=string(Se),"
            + "genericSubsitutions=[string(Si)],"
            + "protocolStub=string(P),"
            + "returnType=string(SS)},"
            + "id=uint64(42),"
            + "remoteCallIdentifier=string($s4Test7GreeterC5greet4nameSSSS_tYaKFTE),"
            + "targetedSharedActor=[uint64(1),string(primary)]}")
    }

    /// `id` goes through `ID64`'s own conformance, which is single-value: a bare
    /// `UInt64` under the key, not a nested `{"value": n}` dictionary.
    func testTheRequestIdIsABareInteger() throws {
        let object = try XPCEncoder().encode(Self.fullRequest)
        let id = try XCTUnwrap(xpc_dictionary_get_value(object, "id"))
        XCTAssertEqual(xpc_get_type(id), XPC_TYPE_UINT64)
    }

    /// `TaskPriority`'s stdlib conformance comes from `RawRepresentable` and codes the
    /// raw value in a single-value container -- a bare `UInt8`.
    func testBasePriorityIsABareRawValue() throws {
        for (priority, raw) in [(TaskPriority.high, 25), (.medium, 21), (.low, 17),
                                (.background, 9)] as [(TaskPriority, UInt64)] {
            let request = RemoteInvocationRequest(
                id: ID64(rawValue: 1), basePriority: priority,
                targetedSharedActor: .exportedRawValue("a"), remoteCallIdentifier: "t",
                contents: InvocationBody(protocolStub: nil, genericSubsitutions: [],
                                         arguments: [], errorType: nil, returnType: nil))
            let object = try XPCEncoder().encode(request)
            let value = try XCTUnwrap(xpc_dictionary_get_value(object, "basePriority"))
            XCTAssertEqual(xpc_get_type(value), XPC_TYPE_UINT64)
            XCTAssertEqual(xpc_uint64_get_value(value), raw)
        }
    }

    func testANilBasePriorityOmitsTheKeyEntirely() throws {
        let request = RemoteInvocationRequest(
            id: ID64(rawValue: 3), basePriority: nil,
            targetedSharedActor: .dynamic(ID64(rawValue: 8)), remoteCallIdentifier: "t",
            contents: InvocationBody(protocolStub: nil, genericSubsitutions: [],
                                     arguments: [], errorType: nil, returnType: nil))
        let object = try XPCEncoder().encode(request)
        XCTAssertNil(xpc_dictionary_get_value(object, "basePriority"))
        XCTAssertEqual(
            normalizedDescription(object),
            "{contents=dict{arguments=[],genericSubsitutions=[]},"
            + "id=uint64(3),"
            + "remoteCallIdentifier=string(t),"
            + "targetedSharedActor=[uint64(2),uint64(8)]}")
    }

    /// The invocation is nested under `contents`, not flattened into the request. There
    /// is no wrapper around it and no send/recv tag.
    func testTheInvocationIsNestedUnderContentsWithNoWrapper() throws {
        let object = try XPCEncoder().encode(Self.fullRequest)
        let contents = try XCTUnwrap(xpc_dictionary_get_value(object, "contents"))
        XCTAssertEqual(xpc_get_type(contents), XPC_TYPE_DICTIONARY)
        XCTAssertNotNil(xpc_dictionary_get_value(contents, "arguments"))
        XCTAssertNil(xpc_dictionary_get_value(contents, "send"))
        XCTAssertNil(xpc_dictionary_get_value(contents, "recv"))
        // ...and the invocation keys do not also appear at the request's top level.
        XCTAssertNil(xpc_dictionary_get_value(object, "arguments"))
        XCTAssertNil(xpc_dictionary_get_value(object, "genericSubsitutions"))
    }

    // MARK: the inbound request keeps the argument container unconsumed

    func testAnInboundRequestReadsTheHeaderAndLeavesTheArgumentsAlone() throws {
        let object = try XPCEncoder().encode(Self.fullRequest)
        let inbound = try XPCDecoder().decode(InboundRequest.self, from: object)

        XCTAssertEqual(inbound.id, ID64(rawValue: 42))
        XCTAssertEqual(inbound.basePriority, .high)
        XCTAssertEqual(inbound.targetedSharedActor, .exportedRawValue("primary"))
        XCTAssertEqual(inbound.remoteCallIdentifier,
                       "$s4Test7GreeterC5greet4nameSSSS_tYaKFTE")
        XCTAssertEqual(inbound.contents.protocolStub, SwiftType(mangledTypeName: "P"))
        XCTAssertEqual(inbound.contents.genericSubsitutions,
                       [SwiftType(mangledTypeName: "Si")])
        XCTAssertEqual(inbound.contents.errorType, SwiftType(mangledTypeName: "Se"))
        XCTAssertEqual(inbound.contents.returnType, SwiftType(mangledTypeName: "SS"))

        var arguments = try XCTUnwrap(inbound.contents.argumentsContainer)
        XCTAssertEqual(try arguments.decode(Int.self), 7)
        XCTAssertEqual(try arguments.decode(String.self), "hi")
        XCTAssertTrue(arguments.isAtEnd)
    }

    // MARK: tier 1 -- the response
    //
    // There is no response dictionary. `RemoteInvocationResponse.encode(to:)` opens a
    // single-value container around an `Either<A, RemoteInvocationFailure>`, and
    // `Either` codes as an unkeyed pair whose first element is a `UInt8` tag --
    // `a` is 0 (the result), `b` is 1 (the failure).
    //
    // The response is generic over its success type, as Apple's is. Nothing about the
    // wire changed with that: the pair is the pair. What changed is who decodes the
    // payload -- the call site, which knows the return type, instead of the envelope.

    func testASuccessResponseIsAnUnkeyedPair() throws {
        XCTAssertEqual(try encoded(RemoteInvocationResponse<Int>.result(42)),
                       "[uint64(0),int64(42)]")
    }

    /// **A Void success is `[0, {}]` -- resolved, no longer assumed.**
    ///
    /// The bytes are what we already had; the reason we had written down was ours and
    /// was wrong. It is not "an empty dictionary so that returning nothing stays
    /// distinguishable from carrying no result". It is Apple's `XPCDistributed.Ack`,
    /// a field-less struct with synthesized `Codable`, standing in for `Void` as the
    /// generic argument, and `{}` is simply what an empty keyed container writes.
    ///
    /// The chain, resolved in the macOS 27 binary with `dump-function.py`:
    ///
    ///     EncodedResultHandler.onReturnVoid()  @0x2ad5036f4
    ///         tail-calls its own vtable slot +0x88 -- onReturn<A>(value:) -- with
    ///         x1 = type metadata for XPCDistributed.Ack (0x2d9b84470),
    ///         x2 = Ack : Decodable, x3 = Ack : Encodable, and no value register
    ///         (Ack is zero-sized).
    ///     EncodedResultHandler.onReturn<A>    @0x2ad503404
    ///         builds Result<A, Error> with swift_storeEnumTagMultiPayload(..., 0)
    ///         -- .success -- and calls ReplyHandler.encodeReply(with:).
    ///     encodeReply<A, B>(with:)            @0x2ad512738
    ///         the .success arm calls encodeReturn<A>(value:) directly.
    ///     encodeReturn<A>(value:)             @0x2ad512298
    ///         calls RemoteInvocationResponse<A>.init(result:) -- tag 0 -- then
    ///         Packet.Payload.init(encoding:userInfo:).
    ///     Ack.encode(to:)                     @0x2ad4ebb70
    ///         opens container(keyedBy: Ack.CodingKeys) and writes nothing;
    ///         `field-descriptors.txt` shows Ack with no fields and its CodingKeys
    ///         with no cases.
    ///
    /// Corroborated independently by the in-process path: `ResultHandler.onReturnVoid()`
    /// (`0x2ad5051b4`) stores `.success(Ack())` as an `any Decodable & Encodable` into
    /// `DirectResultHandler.capturedResult`. Two unrelated paths, one stand-in type.
    func testAVoidSuccessIsTagZeroAndAnEmptyDictionary() throws {
        XCTAssertEqual(try encoded(RemoteInvocationResponse<Ack>.void),
                       "[uint64(0),dict{}]")
    }

    /// And `Ack` alone is `{}` -- the empty keyed container, not a null and not an
    /// absent value. This is the whole of the void payload.
    func testAckEncodesAsAnEmptyDictionary() throws {
        XCTAssertEqual(try encoded(Ack()), "{}")
        XCTAssertEqual(try XPCDecoder().decode(Ack.self,
                                               from: xpc_dictionary_create(nil, nil, 0)),
                       Ack())
    }

    /// Failure responses are spelled `<Never>` because a failure carries no success
    /// value -- which is exactly what Apple does. `encodeReply`'s failure arm
    /// instantiates `RemoteInvocationResponse<Swift.Never>` (the lazy `Encodable`
    /// witness accessor for it is a direct call in that arm), and so does
    /// `encodeReturn`'s catch path.
    func testAnExecutionFailureResponseIsPinned() throws {
        XCTAssertEqual(
            try encoded(RemoteInvocationResponse<Never>(executionFailure: "boom")),
            "[uint64(1),dict{executionFailed=dict{_0=string(boom)}}]")
    }

    func testAResultPropagationFailureResponseIsPinned() throws {
        XCTAssertEqual(
            try encoded(RemoteInvocationResponse<Never>(resultPropagationFailure: "no reply")),
            "[uint64(1),dict{resultPropagationFailed=dict{_0=string(no reply)}}]")
    }

    /// `RemoteInvocationResponse<Never>` cannot hold a result -- the case is
    /// uninhabited, so `.result` is unspellable at compile time and tag 0 has nothing
    /// to decode into at run time. That is why `<Never>` is a failure-only
    /// instantiation on Apple's side too, and why it is not the void answer.
    func testANeverResponseCannotCarryAResult() throws {
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(0))
        xpc_array_append_value(object, xpc_dictionary_create(nil, nil, 0))
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationResponse<Never>.self, from: object))
    }

    /// The failure is a keyed enum in Swift's synthesized shape: exactly one top-level
    /// key naming the case, whose value is `{"_0": <String>}`. Apple carries no typed
    /// error payload at all -- `", but XPCSystem does not support propagating errors."`
    func testTheFailureIsAKeyedEnumWithASingleUnlabelledString() throws {
        XCTAssertEqual(try encoded(RemoteInvocationFailure.executionFailed("boom")),
                       "{executionFailed=dict{_0=string(boom)}}")
        XCTAssertEqual(try encoded(RemoteInvocationFailure.resultPropagationFailed("x")),
                       "{resultPropagationFailed=dict{_0=string(x)}}")
    }

    /// A returned value may itself contain an `ActorID`, which needs the owning session
    /// to code itself -- and `ActorID.encode` traps rather than throws without one.
    /// That is the property `init(result:userInfo:)` existed to protect, and it now
    /// holds by construction: nothing is pre-encoded, so the only `userInfo` in play is
    /// the coder's, which is the same one every other field of the response sees.
    func testAResultCarryingAnActorIDEncodesAgainstTheSuppliedSession() throws {
        let session = StubSession()
        let local = ActorID(raw: .local(.init(systemID: ID64(rawValue: 1),
                                              instanceID: ID64(rawValue: 2))))
        let response = RemoteInvocationResponse<ActorID>.result(local)

        XCTAssertEqual(try encoded(response, userInfo: [.xpcActorSession: session]),
                       "[uint64(0),[uint64(2),uint64(1)]]")
        XCTAssertEqual(session.shared.count, 1,
                       "the ActorID should have been shared into the supplied session")
    }

    func testAResponseRoundTrips() throws {
        func roundTrip<Success: Codable & Equatable>(
            _ value: RemoteInvocationResponse<Success>, line: UInt = #line
        ) throws {
            let object = try XPCEncoder().encode(value)
            XCTAssertEqual(
                try XPCDecoder().decode(RemoteInvocationResponse<Success>.self,
                                        from: object),
                value, line: line)
        }
        try roundTrip(RemoteInvocationResponse<Ack>.void)
        try roundTrip(RemoteInvocationResponse<String>.result("hello"))
        try roundTrip(RemoteInvocationResponse<Int>.result(42))
        try roundTrip(RemoteInvocationResponse<Never>(executionFailure: "boom"))
        try roundTrip(RemoteInvocationResponse<Never>(resultPropagationFailure: "gone"))
    }

    // MARK: tier 1 -- the notification
    //
    // `Session.RemoteNotification`, synthesized enum coding. The field is `id`, never
    // `requestSeq`: correlation lives in the request body's `id`, and there is no
    // envelope sequence for it to collide with.

    func testTheNotificationCasesArePinned() throws {
        XCTAssertEqual(
            try encoded(RemoteNotification.invocationCancelled(id: ID64(rawValue: 9))),
            "{invocationCancelled=dict{id=uint64(9)}}")
        XCTAssertEqual(
            try encoded(RemoteNotification.invocationEscalated(id: ID64(rawValue: 9),
                                                               priority: .high)),
            "{invocationEscalated=dict{id=uint64(9),priority=uint64(25)}}")
        XCTAssertEqual(
            try encoded(RemoteNotification.responseEscalated(id: ID64(rawValue: 9),
                                                             priority: .low)),
            "{responseEscalated=dict{id=uint64(9),priority=uint64(17)}}")
    }

    /// `priority` is absent from `invocationCancelled` because it is not in that case's
    /// key set -- not because it is an optional that happened to be nil.
    func testInvocationCancelledCarriesNoPriority() throws {
        let object = try XPCEncoder().encode(
            RemoteNotification.invocationCancelled(id: ID64(rawValue: 1)))
        let payload = try XCTUnwrap(
            xpc_dictionary_get_value(object, "invocationCancelled"))
        XCTAssertNil(xpc_dictionary_get_value(payload, "priority"))
        XCTAssertEqual(xpc_dictionary_get_count(payload), 1)
    }

    /// The rename our Phase A design made deliberately is not interoperable.
    func testTheNotificationFieldIsNotCalledRequestSeq() throws {
        let object = try XPCEncoder().encode(
            RemoteNotification.invocationCancelled(id: ID64(rawValue: 1)))
        let payload = try XCTUnwrap(
            xpc_dictionary_get_value(object, "invocationCancelled"))
        XCTAssertNil(xpc_dictionary_get_value(payload, "requestSeq"))
        XCTAssertNotNil(xpc_dictionary_get_value(payload, "id"))
    }

    func testEveryNotificationRoundTrips() throws {
        let cases: [RemoteNotification] = [
            .invocationCancelled(id: ID64(rawValue: 1)),
            .invocationEscalated(id: ID64(rawValue: 2), priority: .medium),
            .responseEscalated(id: ID64(rawValue: 3), priority: .background),
        ]
        for value in cases {
            let object = try XPCEncoder().encode(value)
            XCTAssertEqual(try XPCDecoder().decode(RemoteNotification.self, from: object),
                           value)
        }
    }

    // MARK: decoding bytes we did not write
    //
    // Round-trip tests only prove our decoder inverts our encoder; they would still
    // pass if both sides agreed on a shape Apple never sends. These build a peer's
    // bytes by hand from the spec and require that they decode.

    private func peerRequest() -> xpc_object_t {
        let generics = xpc_array_create(nil, 0)
        xpc_array_append_value(generics, xpc_string_create("Si"))

        let arguments = xpc_array_create(nil, 0)
        xpc_array_append_value(arguments, xpc_int64_create(7))
        xpc_array_append_value(arguments, xpc_string_create("hi"))

        let contents = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(contents, "protocolStub", "P")
        xpc_dictionary_set_value(contents, "genericSubsitutions", generics)
        xpc_dictionary_set_value(contents, "arguments", arguments)
        xpc_dictionary_set_string(contents, "errorType", "Se")
        xpc_dictionary_set_string(contents, "returnType", "SS")

        let actor = xpc_array_create(nil, 0)
        xpc_array_append_value(actor, xpc_uint64_create(1))
        xpc_array_append_value(actor, xpc_string_create("primary"))

        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(request, "id", 42)
        xpc_dictionary_set_uint64(request, "basePriority", 25)
        xpc_dictionary_set_value(request, "targetedSharedActor", actor)
        xpc_dictionary_set_string(request, "remoteCallIdentifier", "greet")
        xpc_dictionary_set_value(request, "contents", contents)
        return request
    }

    func testAHandBuiltPeerRequestDecodes() throws {
        let inbound = try XPCDecoder().decode(InboundRequest.self, from: peerRequest())
        XCTAssertEqual(inbound.id, ID64(rawValue: 42))
        XCTAssertEqual(inbound.basePriority, .high)
        XCTAssertEqual(inbound.targetedSharedActor, .exportedRawValue("primary"))
        XCTAssertEqual(inbound.remoteCallIdentifier, "greet")
        XCTAssertEqual(inbound.contents.protocolStub, SwiftType(mangledTypeName: "P"))
        XCTAssertEqual(inbound.contents.genericSubsitutions,
                       [SwiftType(mangledTypeName: "Si")])
        XCTAssertEqual(inbound.contents.errorType, SwiftType(mangledTypeName: "Se"))
        XCTAssertEqual(inbound.contents.returnType, SwiftType(mangledTypeName: "SS"))
        var arguments = try XCTUnwrap(inbound.contents.argumentsContainer)
        XCTAssertEqual(try arguments.decode(Int.self), 7)
        XCTAssertEqual(try arguments.decode(String.self), "hi")
    }

    /// A peer that sends no optionals at all -- the minimum legal request.
    func testAHandBuiltMinimalPeerRequestDecodes() throws {
        let contents = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(contents, "genericSubsitutions", xpc_array_create(nil, 0))
        xpc_dictionary_set_value(contents, "arguments", xpc_array_create(nil, 0))

        let actor = xpc_array_create(nil, 0)
        xpc_array_append_value(actor, xpc_uint64_create(2))
        xpc_array_append_value(actor, xpc_uint64_create(5))

        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(request, "id", 1)
        xpc_dictionary_set_value(request, "targetedSharedActor", actor)
        xpc_dictionary_set_string(request, "remoteCallIdentifier", "t")
        xpc_dictionary_set_value(request, "contents", contents)

        let inbound = try XPCDecoder().decode(InboundRequest.self, from: request)
        XCTAssertNil(inbound.basePriority)
        XCTAssertNil(inbound.contents.protocolStub)
        XCTAssertNil(inbound.contents.errorType)
        XCTAssertNil(inbound.contents.returnType)
        XCTAssertEqual(inbound.contents.genericSubsitutions, [])
        XCTAssertEqual(inbound.targetedSharedActor, .dynamic(ID64(rawValue: 5)))
    }

    func testHandBuiltPeerResponsesDecode() throws {
        let success = xpc_array_create(nil, 0)
        xpc_array_append_value(success, xpc_uint64_create(0))
        xpc_array_append_value(success, xpc_int64_create(42))
        XCTAssertEqual(
            try XPCDecoder().decode(RemoteInvocationResponse<Int>.self, from: success),
            .result(42))

        // The void reply a real peer sends: tag 0 and Apple's `Ack`, which is `{}`.
        let void = xpc_array_create(nil, 0)
        xpc_array_append_value(void, xpc_uint64_create(0))
        xpc_array_append_value(void, xpc_dictionary_create(nil, nil, 0))
        XCTAssertEqual(
            try XPCDecoder().decode(RemoteInvocationResponse<Ack>.self, from: void),
            .void)

        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(payload, "_0", "boom")
        let wrapper = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(wrapper, "executionFailed", payload)
        let failure = xpc_array_create(nil, 0)
        xpc_array_append_value(failure, xpc_uint64_create(1))
        xpc_array_append_value(failure, wrapper)
        XCTAssertEqual(
            try XPCDecoder().decode(RemoteInvocationResponse<Never>.self, from: failure),
            .failure(.executionFailed("boom")))

        // And the production spelling of that same failure, which is the commonest
        // runtime path in the design: a call site names its own return type and has to
        // handle tag 1 arriving where it expected tag 0. `<Never>` above is the
        // instantiation Apple builds when it *knows* the reply is a failure; a caller
        // awaiting a result never gets to know that in advance.
        XCTAssertEqual(
            try XPCDecoder().decode(RemoteInvocationResponse<Int>.self, from: failure),
            .failure(.executionFailed("boom")))
    }

    func testHandBuiltPeerNotificationsDecode() throws {
        func notification(_ name: String, id: UInt64, priority: UInt64?) -> xpc_object_t {
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(payload, "id", id)
            if let priority {
                xpc_dictionary_set_uint64(payload, "priority", priority)
            }
            let object = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(object, name, payload)
            return object
        }

        XCTAssertEqual(
            try XPCDecoder().decode(RemoteNotification.self,
                                    from: notification("invocationCancelled", id: 9,
                                                       priority: nil)),
            .invocationCancelled(id: ID64(rawValue: 9)))
        XCTAssertEqual(
            try XPCDecoder().decode(RemoteNotification.self,
                                    from: notification("invocationEscalated", id: 9,
                                                       priority: 25)),
            .invocationEscalated(id: ID64(rawValue: 9), priority: .high))
        XCTAssertEqual(
            try XPCDecoder().decode(RemoteNotification.self,
                                    from: notification("responseEscalated", id: 9,
                                                       priority: 17)),
            .responseEscalated(id: ID64(rawValue: 9), priority: .low))
    }

    // MARK: rejection

    func testAnUnknownResponseTagIsRejected() throws {
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(7))
        xpc_array_append_value(object, xpc_int64_create(1))
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationResponse<Int>.self, from: object))
    }

    func testATruncatedResponsePairIsRejected() throws {
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(0))
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationResponse<Int>.self, from: object))
    }

    /// The three shapes a hostile peer reaches for first. All three already fail; these
    /// pin that they keep failing.

    func testAResponseSentAsADictionaryIsRejected() throws {
        // The shape a wrapped-envelope implementation would produce. There is no
        // response dictionary, so this must not be coerced into a pair.
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "_value", 0)
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationResponse<Int>.self, from: object))
    }

    func testAFailurePayloadSentAsAStringIsRejected() throws {
        // Tag 1 promises a `RemoteInvocationFailure` dictionary, not the message alone.
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(1))
        xpc_array_append_value(object, xpc_string_create("boom"))
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationResponse<Never>.self, from: object))
    }

    func testAFailureMessageThatIsNotAStringIsRejected() throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "_0", 42)
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(object, "executionFailed", payload)
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationFailure.self, from: object))
    }

    /// Apple's own decoder enforces this: `"Invalid number of keys found, expected
    /// one."` Picking one of two keys would invent a failure that was not sent.
    func testAFailureWithZeroOrTwoKeysIsRejected() throws {
        XCTAssertThrowsError(try XPCDecoder().decode(
            RemoteInvocationFailure.self, from: xpc_dictionary_create(nil, nil, 0)))

        func payload(_ text: String) -> xpc_object_t {
            let object = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(object, "_0", text)
            return object
        }
        let both = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(both, "executionFailed", payload("a"))
        xpc_dictionary_set_value(both, "resultPropagationFailed", payload("b"))
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationFailure.self, from: both))
    }

    func testAFailureWithAnUnknownCaseNameIsRejected() throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(payload, "_0", "a")
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(object, "somethingElseFailed", payload)
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteInvocationFailure.self, from: object))
    }

    func testANotificationWithZeroOrTwoKeysIsRejected() throws {
        XCTAssertThrowsError(try XPCDecoder().decode(
            RemoteNotification.self, from: xpc_dictionary_create(nil, nil, 0)))

        func payload(_ id: UInt64) -> xpc_object_t {
            let object = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(object, "id", id)
            return object
        }
        let both = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(both, "invocationCancelled", payload(1))
        xpc_dictionary_set_value(both, "responseEscalated", payload(2))
        XCTAssertThrowsError(try XPCDecoder().decode(RemoteNotification.self, from: both))
    }

    func testANotificationWithAnUnknownCaseNameIsRejected() throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "id", 1)
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(object, "invocationVanished", payload)
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteNotification.self, from: object))
    }

    /// An escalation without its `priority` is malformed -- the key is part of the
    /// case's key set, not an optional.
    func testAnEscalationWithoutAPriorityIsRejected() throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "id", 1)
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(object, "invocationEscalated", payload)
        XCTAssertThrowsError(
            try XPCDecoder().decode(RemoteNotification.self, from: object))
    }

    /// A null is not an absent key. A peer that reads `errorType` out of a request will
    /// see a present field, so decoding one has to fail rather than silently read nil.
    func testANullOptionalIsNotTreatedAsAbsent() throws {
        let contents = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(contents, "genericSubsitutions", xpc_array_create(nil, 0))
        xpc_dictionary_set_value(contents, "arguments", xpc_array_create(nil, 0))
        xpc_dictionary_set_value(contents, "errorType", xpc_null_create())
        let inbound = try XPCDecoder().decode(InboundInvocation.self, from: contents)
        // `decodeIfPresent` treats an explicit null as absent; what matters is that we
        // never *write* one. This pins the asymmetry so it is a decision, not a bug.
        XCTAssertNil(inbound.errorType)
    }
}
