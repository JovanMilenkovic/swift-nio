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

import XCTest
@testable import NIO

enum EventLoopFutureTestError : Error {
    case example
}

class EventLoopFutureTest : XCTestCase {
    func testFutureFulfilledIfHasResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture(eventLoop: eventLoop, result: 5, file: #file, line: #line)
        XCTAssertTrue(f.fulfilled)
    }

    func testFutureFulfilledIfHasError() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture<Void>(eventLoop: eventLoop, error: EventLoopFutureTestError.example, file: #file, line: #line)
        XCTAssertTrue(f.fulfilled)
    }

    func testAndAllWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Void> = EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
        _ = promises.map { $0.succeed(result: ()) }
        () = try fN.wait()
    }

    func testAndAllWithAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Void> = EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
        _ = promises.map { $0.fail(error: E()) }
        do {
            () = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }

    func testAndAllWithOneFailure() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        var promises: [EventLoopPromise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        _ = promises.map { $0.succeed(result: ()) }
        let failedPromise: EventLoopPromise<()> = eventLoop.newPromise()
        failedPromise.fail(error: E())
        promises.append(failedPromise)

        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Void> = EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
        do {
            () = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }
}
