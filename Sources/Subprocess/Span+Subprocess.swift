//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

import Dispatch

@_unsafeNonescapableResult
@inlinable @inline(__always)
@lifetime(borrow source)
public func _overrideLifetime<
    T: ~Copyable & ~Escapable,
    U: ~Copyable & ~Escapable
>(
    of dependent: consuming T,
    to source: borrowing U
) -> T {
    dependent
}

@_unsafeNonescapableResult
@inlinable @inline(__always)
@lifetime(source)
public func _overrideLifetime<
    T: ~Copyable & ~Escapable,
    U: ~Copyable & ~Escapable
>(
    of dependent: consuming T,
    copyingFrom source: consuming U
) -> T {
    dependent
}

@available(macOS 9999, *)
extension Data {
    init(_ s: borrowing RawSpan) {
        self = s.withUnsafeBytes { Data($0) }
    }

    public var bytes: RawSpan {
        // FIXME: For demo purpose only
        let ptr = self.withUnsafeBytes { ptr in
            return ptr
        }
        let span = RawSpan(_unsafeBytes: ptr)
        return _overrideLifetime(of: span, to: self)
    }
}

@available(macOS 9999, *)
extension DataProtocol {
    var bytes: RawSpan {
        _read {
            if self.regions.isEmpty {
              let empty = UnsafeRawBufferPointer(start: nil, count: 0)
              let span = RawSpan(_unsafeBytes: empty)
              yield _overrideLifetime(of: span, to: self)
            }
            else if self.regions.count == 1 {
                // Easy case: there is only one region in the data
                let ptr = self.regions.first!.withUnsafeBytes { ptr in
                    return ptr
                }
                let span = RawSpan(_unsafeBytes: ptr)
                yield _overrideLifetime(of: span, to: self)
            }
            else {
                // This data contains discontiguous chunks. We have to
                // copy and make a contiguous chunk
                var contiguous: ContiguousArray<UInt8>?
                for region in self.regions {
                    if contiguous != nil {
                        contiguous?.append(contentsOf: region)
                    } else {
                        contiguous = .init(region)
                    }
                }
                let ptr = contiguous!.withUnsafeBytes { ptr in
                    return ptr
                }
                let span = RawSpan(_unsafeBytes: ptr)
                yield _overrideLifetime(of: span, to: self)
            }
        }
    }
}

#if canImport(Glibc) || canImport(Bionic) || canImport(Musl)
@available(macOS 9999, *)
extension DispatchData {
    var bytes: RawSpan {
        _read {
            if self.count == 0 {
                let empty = UnsafeRawBufferPointer(start: nil, count: 0)
                let span = RawSpan(_unsafeBytes: empty)
                yield _overrideLifetime(of: span, to: self)
            } else {
                let ptr = self.withUnsafeBytes {
                    return UnsafeRawBufferPointer(start: UnsafeRawPointer($0), count: self.count)
                }
                let span = RawSpan(_unsafeBytes: ptr)
                yield _overrideLifetime(of: span, to: self)
            }
        }
    }
}
#endif // canImport(Glibc) || canImport(Bionic) || canImport(Musl)

