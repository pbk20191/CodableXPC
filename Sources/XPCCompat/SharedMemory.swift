import XPC
import Darwin

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A typed wrapper over an `XPC_TYPE_SHMEM` object.
    ///
    /// This is a reference type (not a value wrapper) because instances created with
    /// `init(byteCount:)` own the `mmap`ed region backing them and must `munmap` it on
    /// deinit. Instances created with `init(_:)` wrap someone else's shared memory object
    /// and never unmap anything. Apple's overlay provides no Swift type for shared memory
    /// at all.
    ///
    /// To fill in a region you allocated, use `withUnsafeMutableBytes(_:)`; it returns
    /// `nil` on a wrapped instance, which owns no region. Mapping someone else's region
    /// into this process is left to the caller, via `xpc_shmem_map` on `underlying`.
    public final class SharedMemory {
        @usableFromInline
        internal let underlyingShmem: xpc_object_t

        /// Non-nil only when this instance allocated the region itself (via
        /// `init(byteCount:)`) and is therefore responsible for unmapping it on deinit.
        /// Instances created with `init(_:)` always have `owned == nil`: the caller
        /// retains ownership of whatever mapping backs the wrapped object, and this
        /// instance will not unmap anything.
        ///
        /// Stays private — the region is reachable only through the scoped
        /// `withUnsafeMutableBytes(_:)`, so the pointer cannot outlive this instance.
        private let owned: (UnsafeMutableRawPointer, Int)?

        /// Wraps an existing shared memory object. The caller retains ownership of
        /// whatever mapping backs it; this instance will not unmap anything.
        /// - Precondition: `value` is an `XPC_TYPE_SHMEM`.
        public init(_ value: xpc_object_t) {
            precondition(
                xpc_get_type(value) == XPC_TYPE_SHMEM,
                "XPCCompat.SharedMemory requires an XPC_TYPE_SHMEM object"
            )
            self.underlyingShmem = value
            self.owned = nil
        }

        /// Allocates `byteCount` bytes of shareable memory.
        ///
        /// Returns `nil` if the allocation fails. This instance owns the region it
        /// allocates and unmaps it on deinit; callers map it into their own address
        /// space with `xpc_shmem_map`.
        ///
        /// DEVIATION (see task-9-report.md): the original plan allocated the region with
        /// `posix_memalign`, but `xpc_shmem_create`'s header contract requires memory
        /// obtained via `mmap(2)` with `MAP_SHARED` — "memory returned from malloc(3)
        /// may not be safely shared ... because the underlying virtual memory objects
        /// for malloc(3)ed allocations are owned by the malloc(3) subsystem." On this
        /// SDK that contract is enforced at runtime: boxing `posix_memalign`'d memory
        /// traps in `_xpc_shmem_create_with_prot` as API misuse. Using `mmap` with
        /// `MAP_SHARED | MAP_ANON` satisfies the documented contract and is what this
        /// initializer does instead.
        public init?(byteCount: Int) {
            guard byteCount > 0 else { return nil }
            guard let region = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0),
                  region != MAP_FAILED else { return nil }
            self.underlyingShmem = xpc_shmem_create(region, byteCount)
            self.owned = (region, byteCount)
        }

        deinit {
            if let (region, byteCount) = owned {
                munmap(region, byteCount)
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory {
    /// The wrapped `xpc_object_t`, for use with `xpc_shmem_map`.
    public var underlying: xpc_object_t { underlyingShmem }

    /// Calls `body` with the region this instance allocated.
    ///
    /// Returns `nil` without calling `body` if this instance wraps an object it does
    /// not own — i.e. it was built with `init(_:)` rather than `init(byteCount:)`. To
    /// reach someone else's region, map it yourself with `xpc_shmem_map(underlying, …)`.
    ///
    /// This is the only way to reach an `init(byteCount:)` allocation; without it a
    /// caller could allocate bytes and never write to them. The access is scoped on
    /// purpose, so the pointer cannot escape the lifetime of this instance, which
    /// `munmap`s the region on deinit.
    ///
    /// - Warning: The buffer is shared memory. A peer that has mapped the same region
    ///   can read and write it concurrently; this method adds no synchronisation.
    public func withUnsafeMutableBytes<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R? {
        guard let (region, byteCount) = owned else { return nil }
        return try body(UnsafeMutableRawBufferPointer(start: region, count: byteCount))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory: Equatable {
    public static func == (lhs: XPCCompat.SharedMemory, rhs: XPCCompat.SharedMemory) -> Bool {
        xpc_equal(lhs.underlyingShmem, rhs.underlyingShmem)
    }
}

// Hashable for consistency with Dictionary, Array and Endpoint, all of which are
// Equatable + Hashable + CustomDebugStringConvertible. Structural, via xpc_hash,
// matching the xpc_equal-based ==.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlyingShmem))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlyingShmem) }
}
