//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A circular buffer that allows one object at a time to be "marked" and easily identified and retrieved later.
///
/// This object is used extensively within SwiftNIO to handle flushable buffers. It can be used to store buffered
/// writes and mark how far through the buffer the user has flushed, and therefore how far through the buffer is
/// safe to write.
public struct MarkedCircularBuffer<Element>: CustomStringConvertible, AppendableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    public typealias Index = CircularBuffer<Element>.Index

    private var buffer: CircularBuffer<Element>
    private var markedIndexOffset: Int? = nil /* nil: nothing marked */

    /// Create a new instance.
    ///
    /// - paramaters:
    ///     - initialCapacity: The initial capacity of the internal storage.
    public init(initialCapacity: Int) {
        self.buffer = CircularBuffer(initialCapacity: initialCapacity)
    }

    // MARK: Forwarding

    /// Appends an entry to the buffer, expanding it if needed.
    public mutating func append(_ value: Element) {
        if let markedIndexOffset = self.markedIndexOffset {
            self.markedIndexOffset = markedIndexOffset + 1
        }
        self.buffer.append(value)
    }

    /// Removes the first element from the buffer.
    public mutating func removeFirst() -> Element {
        assert(self.buffer.count > 0)
        return self.buffer.removeFirst()
    }

    /// The first element in the buffer.
    public var first: Element? {
        return self.buffer.first
    }

    /// If the buffer is empty.
    public var isEmpty: Bool {
        return self.buffer.isEmpty
    }

    /// The number of elements in the buffer.
    public var count: Int {
        return self.buffer.count
    }

    /// Retrieves the element at the given index from the buffer, without removing it.
    public subscript(index: Index) -> Element {
        get {
            return self.buffer[index]
        }
        set {
            self.buffer[index] = newValue
        }
    }

    /// The valid indices into the buffer.
    public var indices: RangeType<Index> {
        return self.buffer.indices
    }

    public var startIndex: Index { return self.buffer.startIndex }

    public var endIndex: Index { return self.buffer.endIndex }

    public func index(after i: Index) -> Index {
        return self.buffer.index(after: i)
    }

    public var description: String {
        return self.buffer.description
    }

    // MARK: Marking

    /// Marks the buffer at the current index, making the last index in the buffer marked.
    public mutating func mark() {
        let count = self.buffer.count
        if count > 0 {
            self.markedIndexOffset = 1
        } else {
            assert(self.markedElementIndex == nil, "marked index is \(self.markedElementIndex.debugDescription)")
        }
    }

    /// Returns true if the buffer is currently marked at the given index.
    public func isMarked(index: Index) -> Bool {
        assert(index >= self.startIndex, "index must not be negative")
        precondition(index < self.endIndex, "index \(index) out of range (0..<\(self.buffer.count))")
        return self.markedElementIndex == index
    }

    /// Returns the index of the marked element.
    public var markedElementIndex: Index? {
        if let markedIndexOffset = markedIndexOffset {
            let potentialIndex = self.buffer.index(self.endIndex, offsetBy: -markedIndexOffset)
            return self.buffer.indices.contains(potentialIndex) ? potentialIndex : nil
        } else {
            return nil
        }
    }

    /// Returns the marked element.
    public var markedElement: Element? {
        return self.markedElementIndex.map { self.buffer[$0] }
    }

    /// Returns true if the buffer has been marked at all.
    public var hasMark: Bool {
        return self.markedElementIndex != nil
    }
}
