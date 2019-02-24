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
public struct CircularBuffer<Element>: CustomStringConvertible, AppendableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    private var buffer: ContiguousArray<Element?>

    /// The index into the buffer of the first item
    private(set) /* private but tests */ internal var headIdx: Index

    /// The index into the buffer of the next free slot
    private(set) /* private but tests */ internal var tailIdx: Index

    public struct Index: Strideable, Comparable {
        @usableFromInline var _value: ContiguousArray<Element?>.Index
        @usableFromInline var _headValue: ContiguousArray<Element?>.Index
        @usableFromInline let underlyingCount: Int
        @usableFromInline var mask: Int { return self.underlyingCount - 1 }

        @inlinable
        internal init(value: ContiguousArray<Element?>.Index, headValue: ContiguousArray<Element?>.Index, underlyingCount: Int) {
            self._headValue = headValue
            self.underlyingCount = underlyingCount
            self._value = (headValue + value) & (underlyingCount - 1)
        }

        @inlinable
        public func distance(to other: Index) -> Int {
            let head = self._headValue
            if self._value >= head && other._value >= head {
                return self._value.distance(to: other._value)
            } else if self._value >= head && other._value <= head {
                return self._value.distance(to: underlyingCount) + other._value
            } else if self._value <= head && other._value >= head {
                return self._value.distance(to: 0) + underlyingCount.distance(to: other._value)
            } else {
                return self._value.distance(to: other._value)
            }
        }

        @inlinable
        public func advanced(by n: Int) -> Index {
            var index = Index(value: 0, headValue: self._headValue, underlyingCount: self.underlyingCount)
            index._value = (self._value + n) & (self.mask)
            return index
        }

        @inlinable
        public static func < (lhs: Index, rhs: Index) -> Bool {
            let head = lhs._headValue
            if lhs._value >= head && rhs._value >= head {
                return lhs._value < rhs._value
            } else if lhs._value >= head && rhs._value <= head {
                return true
            } else if lhs._value <= head && rhs._value >= head {
                return false
            } else {
                return lhs._value < rhs._value
            }
        }
    }
}

extension CircularBuffer {
    /// Allocates a buffer that can hold up to `initialCapacity` elements and initialise an empty ring backed by
    /// the buffer. When the ring grows to more than `initialCapacity` elements the buffer will be expanded.
    public init(initialCapacity: Int) {
        let capacity = Int(UInt32(initialCapacity).nextPowerOf2())
        self.buffer = ContiguousArray<Element?>(repeating: nil, count: capacity)
        self.headIdx = Index(value: 0, headValue: 0, underlyingCount: capacity)
        self.tailIdx = Index(value: 0, headValue: 0, underlyingCount: capacity)
        assert(self.buffer.count == capacity)
    }

    /// Allocates an empty buffer.
    public init() {
        self.init(initialCapacity: 16)
    }

    /// Append an element to the end of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func append(_ value: Element) {
        self.buffer[self.tailIdx._value] = value
        self.tailIdx = self.index(after: self.tailIdx)

        if self.headIdx == self.tailIdx {
            // No more room left for another append so grow the buffer now.
            self.doubleCapacity()
        }
    }

    /// Prepend an element to the front of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func prepend(_ value: Element) {
        let idx = self.index(before: self.headIdx)
        self.buffer[idx._value] = value
        self.headIdx._value = idx._value
        self.headIdx._headValue = self.headIdx._value
        self.tailIdx._headValue = self.headIdx._value

        if self.headIdx == self.tailIdx {
            // No more room left for another append so grow the buffer now.
            self.doubleCapacity()
        }
    }

    /// Double the capacity of the buffer and adjust the headIdx and tailIdx.
    private mutating func doubleCapacity() {
        var newBacking: ContiguousArray<Element?> = []
        let newCapacity = self.buffer.count << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(self.buffer.count)")
        assert(newCapacity % 2 == 0)

        newBacking.reserveCapacity(newCapacity)
        newBacking.append(contentsOf: self.buffer[self.headIdx._value..<self.buffer.count])
        if self.headIdx._value > 0 {
            newBacking.append(contentsOf: self.buffer[0..<self.headIdx._value])
        }
        let repeatitionCount = newCapacity - newBacking.count
        newBacking.append(contentsOf: repeatElement(nil, count: repeatitionCount))
        self.headIdx = Index(value: 0, headValue: 0, underlyingCount: newBacking.count)
        self.tailIdx = Index(value: newBacking.count - repeatitionCount, headValue: self.headIdx._value, underlyingCount: newBacking.count)
        self.buffer = newBacking
    }
    
    /// Return element `offset` from first element.
    ///
    /// *O(1)*
    public subscript(offset: Int) -> Element {
        get {
            return self[self.index(self.startIndex, offsetBy: offset)]
        }
        set {
            self[self.index(self.startIndex, offsetBy: offset)] = newValue
        }
    }

    // MARK: Collection implementation
    /// Return element `index` of the ring.
    ///
    /// *O(1)*
    public subscript(index: Index) -> Element {
        get {
            return self.buffer[index._value]!
        }
        set {
            self.buffer[index._value] = newValue
        }
    }
    
    /// Return all valid indices of the ring.
    public var indices: RangeType<Index> {
        return self.startIndex ..< self.endIndex
    }

    /// Returns whether the ring is empty.
    public var isEmpty: Bool {
        return self.headIdx == self.tailIdx
    }

    /// Returns the number of element in the ring.
    public var count: Int {
        return self.headIdx.distance(to: self.tailIdx)
    }

    /// The total number of elements that the ring can contain without allocating new storage.
    public var capacity: Int {
        return self.buffer.count
    }

    /// Returns the index of the first element of the ring.
    public var startIndex: Index {
        return self.headIdx
    }

    /// Returns the ring's "past the end" position -- that is, the position one greater than the last valid subscript argument.
    public var endIndex: Index {
        return self.tailIdx
    }

    /// Returns the next index after `index`.
    public func index(after: Index) -> Index {
        return after.advanced(by: 1)
    }

    /// Returns the index before `index`.
    public func index(before: Index) -> Index {
        return before.advanced(by: -1)
    }

    /// Returns the index offset by `distance` from `index`.
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        return i.advanced(by: distance)
    }
    
    /// Removes all members from the circular buffer whist keeping the capacity.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        if keepingCapacity {
            for index in self.startIndex..<self.endIndex {
                self.buffer[index._value] = nil
            }
        } else {
            self.buffer.removeAll(keepingCapacity: false)
            self.buffer.append(nil)
        }
        self.headIdx = Index(value: 0, headValue: 0, underlyingCount: self.buffer.count)
        self.tailIdx = Index(value: 0, headValue: 0, underlyingCount: self.buffer.count)
        assert(self.buffer.allSatisfy { $0 == nil})
    }
    
    // MARK: CustomStringConvertible implementation
    /// Returns a human readable description of the ring.
    public var description: String {
        var desc = "[ "
        for el in self.buffer.enumerated() {
            if el.0 == self.headIdx._value {
                desc += "<"
            } else if el.0 == self.tailIdx._value {
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
    public mutating func replaceSubrange<C>(_ subrange: Range<Index>, with newElements: C) where C : Collection, Element == C.Element {
        precondition(subrange.lowerBound >= self.startIndex && subrange.upperBound <= self.endIndex, "Subrange out of bounds")

        if subrange.count == newElements.count {
            for (index, element) in zip(subrange, newElements) {
                self.buffer[index._value] = element
            }
        } else if subrange.count == self.count && newElements.isEmpty {
            self.removeSubrange(subrange)
        } else {
            var newBuffer: ContiguousArray<Element?> = []
            let neededNewCapacity = self.count + newElements.count - subrange.count + 1 /* always one spare */
            let newCapacity = Swift.max(self.capacity, neededNewCapacity.nextPowerOf2())
            newBuffer.reserveCapacity(newCapacity)

            // This mapping is required due to an inconsistent ability to append sequences of non-optional
            // to optional sequences.
            // https://bugs.swift.org/browse/SR-7921
            newBuffer.append(contentsOf: self[self.startIndex ..< subrange.lowerBound].lazy.map { $0 })
            newBuffer.append(contentsOf: newElements.lazy.map { $0 })
            newBuffer.append(contentsOf: self[subrange.upperBound..<self.endIndex].lazy.map { $0 })

            let repetitionCount = newCapacity - newBuffer.count
            if repetitionCount > 0 {
                newBuffer.append(contentsOf: repeatElement(nil, count: repetitionCount))
            }
            self.buffer = newBuffer
            self.headIdx = Index(value: 0, headValue: 0, underlyingCount: newBuffer.count)
            self.tailIdx = Index(value: newBuffer.count - repetitionCount, headValue: self.headIdx._value, underlyingCount: newBuffer.count)
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
            self.buffer[idx._value] = nil
            idx = self.index(before: idx)
        }
        self.tailIdx = self.tailIdx.advanced(by: -n)
    }

    /// Removes & returns the item at `position` from the buffer
    ///
    /// - Parameter position: The index of the item to be removed from the buffer.
    ///
    /// *O(1)* if the position is `headIdx` or `tailIdx`.
    /// otherwise
    /// *O(n)* where *n* is the number of elements between `position` and `tailIdx`.
    @discardableResult
    public mutating func remove(at position: Index) -> Element {
        precondition(self.indices.contains(position), "Position out of bounds.")
        var bufferIndex = position
        let element = self.buffer[bufferIndex._value]!

        switch bufferIndex {
        case self.headIdx:
            self.headIdx = self.headIdx.advanced(by: 1)
            self.headIdx._headValue = self.headIdx._value
            self.tailIdx._headValue = self.headIdx._value
            self.buffer[bufferIndex._value] = nil
        case self.index(before: self.tailIdx):
            self.tailIdx = self.index(before: self.tailIdx)
            self.buffer[bufferIndex._value] = nil
        default:
            var nextIndex = self.index(after: bufferIndex)
            while nextIndex != self.tailIdx {
                self.buffer[bufferIndex._value] = self.buffer[nextIndex._value]
                bufferIndex = nextIndex
                nextIndex = self.index(after: bufferIndex)
            }
            self.buffer[nextIndex._value] = nil
            self.tailIdx = self.index(before: self.tailIdx)
        }

        return element
    }
}
