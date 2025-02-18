//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

@preconcurrency internal import Dispatch

/// A random and sequential accessible sequence of zero or more bytes.
public struct Buffer: Sendable {
#if os(Windows)
    private var data: [UInt8]

    internal init(data: [UInt8]) {
        self.data = data
    }
#else
    private var data: DispatchData

    internal init(data: DispatchData) {
        self.data = data
    }
#endif
    
    
    /// Access the raw bytes stored in this buffer
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter that
    ///   points to the contiguous storage for the type. If no such storage exists,
    ///   the method creates it. If body has a return value, this method also returns
    ///   that value. The argument is valid only for the duration of the
    ///   closure’s execution.
    /// - Returns: The return value, if any, of the body closure parameter.
    public func withUnsafeBytes<ResultType>(
        _ body: (UnsafeRawBufferPointer) throws -> ResultType
    ) rethrows -> ResultType {
#if os(Windows)
        return try self.data.withUnsafeBytes(body)
#else
        return try self.data.withUnsafeBytes { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: self.data.count)
            return try body(bytes)
        }
#endif
    }
}

// MARK: - Properties
extension Buffer {
    /// Number of bytes stored in the buffer
    public var count: Int {
        return self.data.count
    }

    /// A Boolean value indicating whether the collection is empty.
    public var isEmpty: Bool {
        return self.data.isEmpty
    }
}

// MARK: - Operators
extension Buffer {
    
    /// Appends the specified buffer to the end of this buffer.
    /// - Parameter other: buffer to append
    public mutating func append(_ other: Buffer) {
        var current = self.data
#if os(Windows)
        current.append(contentsOf: other.data)
#else
        current.append(other.data)
#endif
        self.data = current
    }

    /// Creates a new buffer by concatenating two buffers.
    /// - Parameters:
    ///   - lhs: first buffer to concatenate
    ///   - rhs: second buffer to concatenate
    /// - Returns: the new buffer
    public static func +(lhs: Buffer, rhs: Buffer) -> Buffer {
        var result = lhs
        result.append(rhs)
        return result
    }
    
    /// Appends the elements of a buffer to a buffer.
    /// - Parameters:
    ///   - lhs: the buffer to append to
    ///   - rhs: a buffer
    public static func +=(lhs: inout Buffer, rhs: Buffer) {
        lhs.append(rhs)
    }
}

// MARK: - Hashable, Equatable
extension Buffer: Equatable, Hashable {
#if os(Windows)
    // Compiler generated conformances
#else
    public static func == (lhs: Buffer, rhs: Buffer) -> Bool {
        return lhs.data.elementsEqual(rhs.data)
    }

    public func hash(into hasher: inout Hasher) {
        self.data.withUnsafeBytes { ptr in
            let bytes = UnsafeRawBufferPointer(
                start: ptr,
                count: self.data.count
            )
            hasher.combine(bytes: bytes)
        }
    }
#endif
}

// MARK: - RandomAccessCollection
extension Buffer: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = UInt8
    public typealias SubSequence = Slice<Buffer>
    public typealias Indices = Range<Int>

    public subscript(position: Int) -> UInt8 {
        _read {
            yield self.data[position]
        }
    }
    
    public var startIndex: Int {
        return self.data.startIndex
    }
    
    public var endIndex: Int {
        return self.data.endIndex
    }
}
