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

extension Subprocess {
    /// Type-erasing type analogous to `AnySequence` from the Swift standard library.
    struct AnyAsyncSequence<Element>: AsyncSequence {
        private let iteratorFactory: () -> AsyncIterator

        init<S: AsyncSequence>(_ asyncSequence: S) where S.Element == Element {
            self.iteratorFactory = {
                var iterator = asyncSequence.makeAsyncIterator()
                return AsyncIterator { try await iterator.next() }
            }
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            let underlying: () async throws -> Element?

            func next() async throws -> Element? {
                try await self.underlying()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            self.iteratorFactory()
        }
    }

}
