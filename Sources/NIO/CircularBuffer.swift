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

/// AppendableCollection is a protocol partway between Collection and
/// RangeReplaceableCollection. It defines the append method that is present
/// on RangeReplaceableCollection, which makes all RangeReplaceableCollections
/// trivially able to implement this protocol.
protocol AppendableCollection: Collection {
    mutating func append(_ newElement: Self.Iterator.Element)
}

/// An automatically expanding ring buffer implementation backed by a `ContiguousArray`. Even though this implementation
/// will automatically expand if more elements than `initialCapacity` are stored, it's advantageous to prevent
/// expansions from happening frequently. Expansions will always force an allocation and a copy to happen.
public struct CircularBuffer<E>: CustomStringConvertible, AppendableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    
    public struct Index: Comparable, Strideable {
        /* private but tests */ var base: ContiguousArray<E?>.Index
        fileprivate var headBase: ContiguousArray<E?>.Index
        fileprivate let underlyingCount: Int
        private var mask: Int { return self.underlyingCount - 1 }
        
        init(base: ContiguousArray<E?>.Index, headBase: ContiguousArray<E?>.Index, underlyingCount: Int) {
            self.headBase = headBase
            self.underlyingCount = underlyingCount
            self.base = (headBase + base) & (underlyingCount - 1)
        }
        
        public static func < (lhs: Index, rhs: Index) -> Bool {
            let head = lhs.headBase
            if lhs.base >= head && rhs.base >= head {
                return lhs.base < rhs.base
            } else if lhs.base >= head && rhs.base <= head {
                return true
            } else if lhs.base <= head && rhs.base >= head {
                return false
            } else {
                return lhs.base < rhs.base
            }
        }
        
        public func distance(to other: Index) -> Int {
            let head = self.headBase
            if self.base >= head && other.base >= head {
                return self.base.distance(to: other.base)
            } else if self.base >= head && other.base <= head {
                return self.base.distance(to: underlyingCount) + other.base
            } else if self.base <= head && other.base >= head {
                return self.base.distance(to: 0) + underlyingCount.distance(to: other.base)
            } else {
                return self.base.distance(to: other.base)
            }
        }
        
        public func advanced(by n: Int) -> Index {
            var index = Index(base: 0, headBase: self.headBase, underlyingCount: self.underlyingCount)
            index.base = (self.base + n) & (self.mask)
            return index
        }
    }
    
    private var buffer: ContiguousArray<E?>

    /// The index into the buffer of the first item
    private(set) /* private but tests */ internal var headIdx: Index

    /// The index into the buffer of the next free slot
    private(set) /* private but tests */ internal var tailIdx: Index

    /// Allocates a buffer that can hold up to `initialCapacity` elements and initialise an empty ring backed by
    /// the buffer. When the ring grows to more than `initialCapacity` elements the buffer will be expanded.
    public init(initialCapacity: Int) {
        let capacity = Int(UInt32(initialCapacity).nextPowerOf2())
        self.buffer = ContiguousArray<E?>(repeating: nil, count: capacity)
        self.headIdx = Index(base: 0, headBase: 0, underlyingCount: capacity)
        self.tailIdx = Index(base: 0, headBase: 0, underlyingCount: capacity)
        assert(self.buffer.count == capacity)
    }

    /// Allocates an empty buffer.
    public init() {
        self.init(initialCapacity: 16)
    }

    /// Append an element to the end of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func append(_ value: E) {
        self.buffer[self.tailIdx.base] = value
        self.tailIdx = self.index(after: self.tailIdx)

        if self.headIdx == self.tailIdx {
            // No more room left for another append so grow the buffer now.
            self.doubleCapacity()
        }
    }

    /// Prepend an element to the front of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func prepend(_ value: E) {
        let idx = self.index(before: self.headIdx)
        self.buffer[idx.base] = value
        self.headIdx.base = idx.base
        self.headIdx.headBase = self.headIdx.base
        self.tailIdx.headBase = self.headIdx.base
        
        if self.headIdx == self.tailIdx {
            // No more room left for another append so grow the buffer now.
            self.doubleCapacity()
        }
    }

    /// Double the capacity of the buffer and adjust the headIdx and tailIdx.
    private mutating func doubleCapacity() {
        var newBacking: ContiguousArray<E?> = []
        let newCapacity = self.buffer.count << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(self.buffer.count)")
        assert(newCapacity % 2 == 0)

        newBacking.reserveCapacity(newCapacity)
        newBacking.append(contentsOf: self.buffer[self.headIdx.base..<self.buffer.count])
        if self.headIdx.base > 0 {
            newBacking.append(contentsOf: self.buffer[0..<self.headIdx.base])
        }
        let repeatitionCount = newCapacity - newBacking.count
        newBacking.append(contentsOf: repeatElement(nil, count: repeatitionCount))
        self.headIdx = Index(base: 0, headBase: 0, underlyingCount: newBacking.count)
        self.tailIdx = Index(base: newBacking.count - repeatitionCount, headBase: self.headIdx.base, underlyingCount: newBacking.count)
        self.buffer = newBacking
    }

    // MARK: Collection implementation
    /// Return element `index` of the ring.
    ///
    /// *O(1)*
    public subscript(index: Index) -> E {
        get {
            return self.buffer[index.base]!
        }
        set {
            self.buffer[index.base] = newValue
        }
    }
    
    public subscript(offset: Int) -> E {
        get {
            return self[self.index(self.startIndex, offsetBy: offset)]
        }
        set {
            self[self.index(self.startIndex, offsetBy: offset)] = newValue
        }
    }

    /// Return all valid indices of the ring.
    public var indices: RangeType<Index> { return self.startIndex ..< self.endIndex }

    /// Returns whether the ring is empty.
    public var isEmpty: Bool { return self.headIdx == self.tailIdx }

    /// Returns the number of element in the ring.
    public var count: Int { return (self.headIdx.distance(to: self.tailIdx)) }

    /// The total number of elements that the ring can contain without allocating new storage.
    public var capacity: Int { return self.buffer.count }

    /// Returns the index of the first element of the ring.
    public var startIndex: Index { return self.headIdx }

    /// Returns the ring's "past the end" position -- that is, the position one greater than the last valid subscript argument.
    public var endIndex: Index { return self.tailIdx }

    /// Returns the next index after `index`.
    public func index(after i: Index) -> Index { return i.advanced(by: 1) }

    /// Returns the index before `index`.
    public func index(before i: Index) -> Index { return i.advanced(by: -1) }

    /// Removes all members from the circular buffer whist keeping the capacity.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        self.buffer = ContiguousArray<E?>(repeating: nil, count: keepingCapacity ? self.buffer.count : 1)
        self.headIdx = Index(base: 0, headBase: 0, underlyingCount: self.buffer.count)
        self.tailIdx = Index(base: 0, headBase: 0, underlyingCount: self.buffer.count)
    }

    // MARK: CustomStringConvertible implementation
    /// Returns a human readable description of the ring.
    public var description: String {
        var desc = "[ "
        for el in self.buffer.enumerated() {
            if el.0 == self.headIdx.base {
                desc += "<"
            } else if el.0 == self.tailIdx.base {
                desc += ">"
            }
            desc += el.1.map { "\($0) " } ?? "_ "
        }
        desc += "]"
        desc += " (bufferCapacity: \(self.buffer.count), ringLength: \(self.count))"
        return desc
    }
}

// MARK: - BidirectionalCollection, RandomAccessCollection, RangeReplaceableCollection
extension CircularBuffer: BidirectionalCollection, RandomAccessCollection, RangeReplaceableCollection {
    /// Replaces the specified subrange of elements with the given collection.
    ///
    /// - Parameter subrange:
    /// The subrange of the collection to replace. The bounds of the range must be valid indices of the collection.
    ///
    /// - Parameter newElements:
    /// The new elements to add to the collection.
    ///
    /// *O(n)* where _n_ is the length of the new elements collection if the subrange equals to _n_
    ///
    /// *O(m)* where _m_ is the combined length of the collection and _newElements_
    public mutating func replaceSubrange<C>(_ subrange: Range<Index>, with newElements: C) where C : Collection, E == C.Element {
        precondition(subrange.lowerBound >= self.startIndex && subrange.upperBound <= self.endIndex, "Subrange out of bounds")

        if subrange.count == newElements.count {
            for (index, element) in zip(subrange, newElements) {
                self.buffer[index.base] = element
            }
        } else if subrange.count == self.count && newElements.isEmpty {
            self.removeSubrange(subrange)
        } else {
            var newBuffer: ContiguousArray<E?> = []
            let neededNewCapacity = self.count + newElements.count - subrange.count + 1 /* always one spare */
            let newCapacity = Swift.max(self.capacity, neededNewCapacity.nextPowerOf2())
            newBuffer.reserveCapacity(newCapacity)

            // This mapping is required due to an inconsistent ability to append sequences of non-optional
            // to optional sequences.
            // https://bugs.swift.org/browse/SR-7921
            newBuffer.append(contentsOf: self[self.startIndex..<subrange.lowerBound].lazy.map { $0 })
            newBuffer.append(contentsOf: newElements.lazy.map { $0 })
            newBuffer.append(contentsOf: self[subrange.upperBound..<self.endIndex].lazy.map { $0 })

            let repetitionCount = newCapacity - newBuffer.count
            if repetitionCount > 0 {
                newBuffer.append(contentsOf: repeatElement(nil, count: repetitionCount))
            }
            self.buffer = newBuffer
            self.headIdx = Index(base: 0, headBase: 0, underlyingCount: newBuffer.count)
            self.tailIdx = Index(base: newBuffer.count - repetitionCount, headBase: self.headIdx.base, underlyingCount: newBuffer.count)
        }
    }

    /// Removes the elements in the specified subrange from the circular buffer.
    ///
    /// - Parameter bounds: The range of the circular buffer to be removed. The bounds of the range must be valid indices of the collection.
    public mutating func removeSubrange(_ bounds: Range<Index>) {
        precondition(bounds.upperBound >= self.startIndex && bounds.upperBound <= self.endIndex, "Invalid bounds.")
        switch bounds.count {
        case 1:
            remove(at: bounds.lowerBound)
        case self.count:
            self = .init(initialCapacity: self.buffer.count)
        default:
            replaceSubrange(bounds, with: [])
        }
    }

    /// Removes the given number of elements from the end of the collection.
    ///
    /// - Parameter n: The number of elements to remove from the tail of the buffer.
    public mutating func removeLast(_ n: Int) {
        precondition(n <= self.count, "Number of elements to drop bigger than the amount of elements in the buffer.")
        var idx = self.tailIdx
        for _ in 0 ..< n {
            self.buffer[idx.base] = nil
            idx = self.index(before: idx)
        }
        self.tailIdx = self.index(self.tailIdx, offsetBy: -n)
    }

    /// Removes & returns the item at `position` from the buffer
    ///
    /// - Parameter position: The index of the item to be removed from the buffer.
    ///
    /// *O(1)* if the position is `headIdx` or `tailIdx`.
    /// otherwise
    /// *O(n)* where *n* is the number of elements between `position` and `tailIdx`.
    @discardableResult
    public mutating func remove(at position: Index) -> E {
        precondition(self.indices.contains(position), "Position out of bounds.")
        var bufferIndex = position
        let element = self.buffer[bufferIndex.base]!

        switch bufferIndex {
        case self.headIdx:
            self.headIdx = self.headIdx.advanced(by: 1)
            self.headIdx.headBase = self.headIdx.base
            self.tailIdx.headBase = self.headIdx.base
            self.buffer[bufferIndex.base] = nil
        case self.index(before: self.tailIdx):
            self.tailIdx = self.index(before: self.tailIdx)
            self.buffer[bufferIndex.base] = nil
        default:
            var nextIndex = self.index(after: bufferIndex)
            while nextIndex != self.tailIdx {
                self.buffer[bufferIndex.base] = self.buffer[nextIndex.base]
                bufferIndex = nextIndex
                nextIndex = self.index(after: bufferIndex)
            }
            self.buffer[nextIndex.base] = nil
            self.tailIdx = self.index(before: self.tailIdx)
        }

        return element
    }
}

