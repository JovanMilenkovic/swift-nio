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

import Dispatch
import NIOPriorityQueue

private final class EmbeddedScheduledTask {
    let task: () -> ()
    let readyTime: UInt64

    init(readyTime: UInt64, task: @escaping () -> ()) {
        self.readyTime = readyTime
        self.task = task
    }
}

extension EmbeddedScheduledTask: Comparable {
    public static func < (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    public static func == (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs === rhs
    }
}

/// An `EventLoop` that is embedded in the current running context with no external
/// control.
///
/// Unlike more complex `EventLoop`s, such as `SelectableEventLoop`, the `EmbeddedEventLoop`
/// has no proper eventing mechanism. Instead, reads and writes are fully controlled by the
/// entity that instantiates the `EmbeddedEventLoop`. This property makes `EmbeddedEventLoop`
/// of limited use for many application purposes, but highly valuable for testing and other
/// kinds of mocking.
///
/// - warning: Unlike `SelectableEventLoop`, `EmbeddedEventLoop` **is not thread-safe**. This
///     is becuase it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into the `EmbeddedEventLoop` in an
///     unsynchronized fashion.
public class EmbeddedEventLoop: EventLoop {
    /// The current "time" for this event loop. This is an amount in nanoseconds.
    private var now: UInt64 = 0

    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>(ascending: true)

    public var inEventLoop: Bool {
        return true
    }

    var tasks = CircularBuffer<() -> ()>(initialRingCapacity: 2)
    
    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws-> (T)) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = newPromise()
        let readyTime = now + UInt64(`in`.nanoseconds)
        let task = EmbeddedScheduledTask(readyTime: readyTime) {
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.scheduledTasks.remove(task)
        })
        scheduledTasks.push(task)
        return scheduled
    }
    
    // We're not really running a loop here. Tasks aren't run until run() is called,
    // at which point we run everything that's been submitted. Anything newly submitted
    // either gets on that train if it's still moving or waits until the next call to run().
    public func execute(task: @escaping () -> ()) {
        tasks.append(task)
    }

    public func run() {
        // Execute all tasks that are currently enqueued.
        while !tasks.isEmpty {
            tasks.removeFirst()()
        }
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by: TimeAmount) {
        let newTime = self.now + UInt64(by.nanoseconds)

        // First, run the event loop to dispatch any current work.
        self.run()

        while let nextTask = self.scheduledTasks.peek() {
            guard nextTask.readyTime <= newTime else {
                break
            }

            // Set the time correctly before we call into user code, then
            // call in. Once we've done that, spin the event loop in case any
            // work was scheduled by the delayed task.
            _ = self.scheduledTasks.pop()
            self.now = nextTask.readyTime
            nextTask.task()

            self.run()
        }

        // Finally ensure we got the time right.
        self.now = newTime
    }

    func close() throws {
        // Nothing to do here
    }

    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        run()
        queue.sync {
            callback(nil)
        }
    }

    deinit {
        precondition(tasks.isEmpty, "Embedded event loop freed with unexecuted tasks!")
        precondition(scheduledTasks.isEmpty, "Embedded event loop freed with unexecuted scheduled tasks!")
    }
}

class EmbeddedChannelCore : ChannelCore {
    var closed: Bool = false
    var isActive: Bool = false

    
    var eventLoop: EventLoop
    var closePromise: EventLoopPromise<Void>
    var error: Error?
    
    private unowned let pipeline: ChannelPipeline

    init(pipeline: ChannelPipeline, eventLoop: EventLoop) {
        closePromise = eventLoop.newPromise()
        self.pipeline = pipeline
        self.eventLoop = eventLoop
    }
    
    deinit {
        closed = true
        closePromise.succeed(result: ())
    }

    var outboundBuffer: [IOData] = []
    var inboundBuffer: [NIOAny] = []
    
    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if closed {
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }
        closed = true
        promise?.succeed(result: ())

        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        isActive = false
        pipeline.fireChannelInactive0()
        pipeline.fireChannelUnregistered0()
        
        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            self.closePromise.succeed(result: ())
        }
    }

    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
        pipeline.fireChannelRegistered0()
        isActive = true
        pipeline.fireChannelActive0()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    func write0(data: IOData, promise: EventLoopPromise<Void>?) {
        addToBuffer(buffer: &outboundBuffer, data: data)
        promise?.succeed(result: ())
    }

    func flush0(promise: EventLoopPromise<Void>?) {
        if closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        promise?.succeed(result: ())
    }

    func read0(promise: EventLoopPromise<Void>?) {
        if closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        promise?.succeed(result: ())
    }
    
    public final func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }
    
    func channelRead0(data: NIOAny) {
        addToBuffer(buffer: &inboundBuffer, data: data)
    }
    
    public func errorCaught0(error: Error) {
        if self.error == nil {
            self.error = error
        }
    }
    
    private func addToBuffer<T>(buffer: inout [T], data: T) {
        buffer.append(data)
    }
}

public class EmbeddedChannel : Channel {
    public var isActive: Bool { return channelcore.isActive }
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    private lazy var channelcore: EmbeddedChannelCore = EmbeddedChannelCore(pipeline: self._pipeline, eventLoop: self.eventLoop)

    public var _unsafe: ChannelCore {
        return channelcore
    }
    
    public var pipeline: ChannelPipeline {
        return _pipeline
    }

    public var isWritable: Bool {
        return true
    }
    
    public func finish() throws -> Bool {
        try close().wait()
        try throwIfErrorCaught()
        return !channelcore.outboundBuffer.isEmpty || !channelcore.inboundBuffer.isEmpty
    }
    
    private var _pipeline: ChannelPipeline!
    public let allocator: ByteBufferAllocator = ByteBufferAllocator()
    public var eventLoop: EventLoop = EmbeddedEventLoop()

    public var localAddress: SocketAddress? = nil
    public var remoteAddress: SocketAddress? = nil

    // Embedded channels never have parents.
    public let parent: Channel? = nil
    
    public func readOutbound() -> IOData? {
        return readFromBuffer(buffer: &channelcore.outboundBuffer)
    }
    
    public func readInbound<T>() -> T? {
        return readFromBuffer(buffer: &channelcore.inboundBuffer)
    }
    
    @discardableResult public func writeInbound<T>(data: T) throws -> Bool {
        pipeline.fireChannelRead(data: NIOAny(data))
        pipeline.fireChannelReadComplete()
        try throwIfErrorCaught()
        return !channelcore.inboundBuffer.isEmpty
    }
    
    @discardableResult public func writeOutbound<T>(data: T) throws -> Bool {
        try writeAndFlush(data: NIOAny(data)).wait()
        return !channelcore.outboundBuffer.isEmpty
    }
    
    public func throwIfErrorCaught() throws {
        if let error = channelcore.error {
            channelcore.error = nil
            throw error
        }
    }

    private func readFromBuffer(buffer: inout [IOData]) -> IOData? {
        if buffer.isEmpty {
            return nil
        }
        return buffer.removeFirst()
    }

    private func readFromBuffer<T>(buffer: inout [NIOAny]) -> T? {
        if buffer.isEmpty {
            return nil
        }
        return (buffer.removeFirst().forceAs(type: T.self))
    }
    
    public init() {
        _pipeline = ChannelPipeline(channel: self)
        
        // we should just register it directly and this will never throw.
        _ = try? register().wait()
    }
    
    public init(handler: ChannelHandler) throws {
        _pipeline = ChannelPipeline(channel: self)
        try _pipeline.add(handler: handler).wait()
        
        // we should just register it directly and this will never throw.
        _ = try? register().wait()
    }

    public func setOption<T>(option: T, value: T.OptionType) throws where T : ChannelOption {
        // No options supported
    }

    public func getOption<T>(option: T) throws -> T.OptionType where T : ChannelOption {
        if option is AutoReadOption {
            return true as! T.OptionType
        }
        fatalError("option \(option) not supported")
    }
}
