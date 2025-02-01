//
//  SpanStubs.swift
//  SwiftExperimentalSubprocess
//
//  Created by Charles Hu on 1/29/25.
//

import Foundation
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
            guard self.regions.isEmpty else {
                fatalError("Empty DispatchData read")
            }
            // Easy case: there is only one region in the data
            if self.regions.count == 1 {
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
