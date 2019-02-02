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
public struct MarkedCircularBuffer<E>: CustomStringConvertible, AppendableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger

    public struct Index: Comparable, Strideable {
        let base: CircularBuffer<E>.Index
        
        public static func < (lhs: Index, rhs: Index) -> Bool {
            return lhs.base < rhs.base
        }
        
        public func distance(to other: Index) -> Int {
            return self.base.distance(to: other.base)
        }
        
        public func advanced(by n: Int) -> Index {
            return Index(base: self.base.advanced(by: n))
        }
        
    }
    private var buffer: CircularBuffer<E>
    private var markedIndex: Index? = nil

    /// Create a new instance.
    ///
    /// - paramaters:
    ///     - initialCapacity: The initial capacity of the internal storage.
    public init(initialCapacity: Int) {
        self.buffer = CircularBuffer(initialCapacity: initialCapacity)
    }

    // MARK: Forwarding

    /// Appends an entry to the buffer, expanding it if needed.
    public mutating func append(_ value: E) {
        self.buffer.append(value)
    }

    /// Removes the first element from the buffer.
    public mutating func removeFirst() -> E {
        assert(self.buffer.count > 0)
        self.markedIndex = self.markedIndex?.advanced(by: -1)
        if let markedIndex = self.markedIndex, markedIndex < self.startIndex {
            self.markedIndex = nil
        }
        return self.buffer.removeFirst()
    }

    /// The first element in the buffer.
    public var first: E? {
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
    public subscript(index: Index) -> E {
        get {
            return self.buffer[index.base]
        }
        set {
            self.buffer[index.base] = newValue
        }
    }
    
    public subscript(offset: Int) -> E {
        get {
            return self.buffer[offset]
        }
        set {
            self.buffer[offset] = newValue
        }
    }

    /// The valid indices into the buffer.
    public var indices: RangeType<Index> {
        return Index(base: self.buffer.indices.startIndex) ..< Index(base: self.buffer.indices.endIndex)
    }

    public var startIndex: Index { return Index(base: self.buffer.startIndex) }

    public var endIndex: Index { return Index(base: self.buffer.endIndex) }

    public func index(after i: Index) -> Index { return Index(base: self.buffer.index(after: i.base)) }

    public var description: String {
        return self.buffer.description
    }

    // MARK: Marking

    /// Marks the buffer at the current index, making the last index in the buffer marked.
    public mutating func mark() {
        let count = self.buffer.count
        if count > 0 {
            self.markedIndex = endIndex.advanced(by: -1)
        } else {
            assert(self.markedIndex == nil, "marked index is \(self.markedIndex!)")
        }
    }

    /// Returns true if the buffer is currently marked at the given index.
    public func isMarked(index: Index) -> Bool {
        precondition(index >= self.startIndex, "index must not be before start index")
        precondition(index < self.endIndex, "index \(index) out of range")
        return self.markedIndex == index
    }

    /// Returns the index of the marked element.
    public var markedElementIndex: Index? {
        return markedIndex
    }

    /// Returns the marked element.
    public var markedElement: E? {
        return self.markedElementIndex.map { self.buffer[$0.base] }
    }

    /// Returns true if the buffer has been marked at all.
    public var hasMark: Bool {
        return self.markedIndex != nil
    }
}
