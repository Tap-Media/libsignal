//
// Copyright 2024 Signal Messenger, LLC.
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalFfi

// These testing endpoints aren't generated in device builds, to save on code size.
#if !os(iOS) || targetEnvironment(simulator)

extension AuthenticatedChatConnection {
    internal static func fakeConnect(
        tokioAsyncContext: TokioAsyncContext, listener: any ChatConnectionListener,
        alerts: [String] = []
    ) -> (AuthenticatedChatConnection, FakeChatRemote) {
        let (fakeChatConnection, listenerBridge) = failOnError {
            try FakeChatConnection.create(
                tokioAsyncContext: tokioAsyncContext, listener: listener, alerts: alerts
            )
        }

        return failOnError {
            var chatHandle = SignalMutPointerAuthenticatedChatConnection(untyped: nil)
            try fakeChatConnection.withNativeHandle {
                try checkError(
                    signal_testing_fake_chat_connection_take_authenticated_chat(
                        &chatHandle, $0.const()
                    ))
            }
            let chat = AuthenticatedChatConnection(
                fakeHandle: NonNull(chatHandle)!, tokioAsyncContext: tokioAsyncContext
            )

            listenerBridge.setConnection(chatConnection: chat)
            var fakeRemoteHandle = SignalMutPointerFakeChatRemoteEnd()
            try fakeChatConnection.withNativeHandle {
                try checkError(
                    signal_testing_fake_chat_connection_take_remote(
                        &fakeRemoteHandle, $0.const()
                    ))
            }

            let fakeRemote = FakeChatRemote(
                handle: NonNull(fakeRemoteHandle)!, tokioAsyncContext: tokioAsyncContext
            )
            return (chat, fakeRemote)
        }
    }
}

extension UnauthenticatedChatConnection {
    internal static func fakeConnect(
        tokioAsyncContext: TokioAsyncContext,
        listener: any ConnectionEventsListener<UnauthenticatedChatConnection>
    ) -> (UnauthenticatedChatConnection, FakeChatRemote) {
        let (fakeChatConnection, listenerBridge) = failOnError {
            try FakeChatConnection.create(
                tokioAsyncContext: tokioAsyncContext, listener: listener, alerts: []
            )
        }

        return failOnError {
            var chatHandle = SignalMutPointerAuthenticatedChatConnection(untyped: nil)
            try fakeChatConnection.withNativeHandle {
                try checkError(
                    signal_testing_fake_chat_connection_take_authenticated_chat(
                        &chatHandle, $0.const()
                    ))
            }
            let chat = UnauthenticatedChatConnection(
                fakeHandle: NonNull(chatHandle)!, tokioAsyncContext: tokioAsyncContext
            )

            listenerBridge.setConnection(chatConnection: chat)
            var fakeRemoteHandle = SignalMutPointerFakeChatRemoteEnd()
            try fakeChatConnection.withNativeHandle {
                try checkError(
                    signal_testing_fake_chat_connection_take_remote(
                        &fakeRemoteHandle, $0.const()
                    ))
            }

            let fakeRemote = FakeChatRemote(
                handle: NonNull(fakeRemoteHandle)!, tokioAsyncContext: tokioAsyncContext
            )
            return (chat, fakeRemote)
        }
    }
}

private class SetChatLaterListenerBridge: ChatListenerBridge {
    private var savedAlerts: [String]?

    override init(chatConnectionListenerForTesting chatListener: any ChatConnectionListener) {
        super.init(chatConnectionListenerForTesting: chatListener)
    }

    func setConnection(chatConnection: AuthenticatedChatConnection) {
        self.chatConnection = chatConnection

        if let savedAlerts {
            super.didReceiveAlerts(savedAlerts)
            self.savedAlerts = nil
        }
    }

    // Override point for ChatConnection+Fake.
    override func didReceiveAlerts(_ alerts: [String]) {
        // This callback can happen before setConnection, so we might need to replay it later.
        guard self.chatConnection != nil else {
            self.savedAlerts = alerts
            return
        }

        super.didReceiveAlerts(alerts)
    }
}

private class SetChatLaterUnauthListenerBridge: UnauthConnectionEventsListenerBridge {
    override init(chatConnectionEventsListenerForTesting chatListener: any ConnectionEventsListener<UnauthenticatedChatConnection>) {
        super.init(chatConnectionEventsListenerForTesting: chatListener)
    }

    func setConnection(chatConnection: UnauthenticatedChatConnection) {
        self.chatConnection = chatConnection
    }
}

internal class FakeChatRemote: NativeHandleOwner<SignalMutPointerFakeChatRemoteEnd> {
    private let tokioAsyncContext: TokioAsyncContext

    required init(owned: NonNull<SignalMutPointerFakeChatRemoteEnd>) {
        fatalError("must not be invoked directly")
    }

    init(
        handle: NonNull<SignalMutPointerFakeChatRemoteEnd>, tokioAsyncContext: TokioAsyncContext
    ) {
        self.tokioAsyncContext = tokioAsyncContext
        super.init(owned: handle)
    }

    func injectServerRequest(base64: String) {
        self.injectServerRequest(Data(base64Encoded: base64)!)
    }

    func injectServerRequest(_ requestBytes: Data) {
        withNativeHandle { handle in
            requestBytes.withUnsafeBorrowedBuffer { requestBytes in
                failOnError(
                    signal_testing_fake_chat_remote_end_send_raw_server_request(
                        handle.const(), requestBytes
                    ))
            }
        }
    }

    func getNextIncomingRequest() async throws -> (ChatRequest.InternalRequest, UInt64) {
        let request = try await self.tokioAsyncContext.invokeAsyncFunction { promise, asyncContext in
            withNativeHandle { handle in
                signal_testing_fake_chat_remote_end_receive_incoming_request(
                    promise, asyncContext.const(), handle.const()
                )
            }
        }
        defer { signal_fake_chat_sent_request_destroy(request) }

        let httpRequest: ChatRequest.InternalRequest =
            try invokeFnReturningNativeHandle {
                signal_testing_fake_chat_sent_request_take_http_request($0, request)
            }
        let requestId = try invokeFnReturningInteger {
            signal_testing_fake_chat_sent_request_request_id($0, request.const())
        }

        return (httpRequest, requestId)
    }

    func injectServerResponse(base64: String) {
        self.injectServerResponse(Data(base64Encoded: base64)!)
    }

    func injectServerResponse(_ responseBytes: Data) {
        withNativeHandle { handle in
            responseBytes.withUnsafeBorrowedBuffer { responseBytes in
                failOnError(
                    signal_testing_fake_chat_remote_end_send_raw_server_response(
                        handle.const(), responseBytes
                    ))
            }
        }
    }

    func injectConnectionInterrupted() {
        withNativeHandle { handle in
            failOnError(
                signal_testing_fake_chat_remote_end_inject_connection_interrupted(
                    handle.const()))
        }
    }

    override class func destroyNativeHandle(
        _ handle: NonNull<SignalMutPointerFakeChatRemoteEnd>
    ) -> SignalFfiErrorRef? {
        signal_fake_chat_remote_end_destroy(handle.pointer)
    }
}

private class FakeChatConnection: NativeHandleOwner<SignalMutPointerFakeChatConnection> {
    static func create(
        tokioAsyncContext: TokioAsyncContext, listener: any ChatConnectionListener,
        alerts: [String]
    ) throws -> (FakeChatConnection, SetChatLaterListenerBridge) {
        let listenerBridge = SetChatLaterListenerBridge(
            chatConnectionListenerForTesting: listener)
        var listenerStruct = listenerBridge.makeListenerStruct()
        let chat = try FakeChatConnection.internalCreate(tokioAsyncContext, &listenerStruct, alerts)
        return (chat, listenerBridge)
    }

    static func create(
        tokioAsyncContext: TokioAsyncContext, listener: any ConnectionEventsListener<UnauthenticatedChatConnection>,
        alerts: [String]
    ) throws -> (FakeChatConnection, SetChatLaterUnauthListenerBridge) {
        let listenerBridge = SetChatLaterUnauthListenerBridge(
            chatConnectionEventsListenerForTesting: listener)
        var listenerStruct = listenerBridge.makeListenerStruct()
        let chat = try FakeChatConnection.internalCreate(tokioAsyncContext, &listenerStruct, alerts)
        return (chat, listenerBridge)
    }

    private static func internalCreate(_ tokioAsyncContext: TokioAsyncContext, _ listenerStruct: inout SignalFfiChatListenerStruct, _ alerts: [String]) throws -> FakeChatConnection {
        let connection: FakeChatConnection = try withUnsafePointer(to: &listenerStruct) { listener in
            try tokioAsyncContext.withNativeHandle { asyncContext in
                try invokeFnReturningNativeHandle {
                    signal_testing_fake_chat_connection_create(
                        $0,
                        asyncContext.const(),
                        SignalConstPointerFfiChatListenerStruct(raw: listener),
                        alerts.joined(separator: "\n")
                    )
                }
            }
        }
        return connection
    }

    override class func destroyNativeHandle(
        _ handle: NonNull<SignalMutPointerFakeChatConnection>
    ) -> SignalFfiErrorRef? {
        signal_fake_chat_connection_destroy(handle.pointer)
    }
}

extension SignalMutPointerFakeChatConnection: SignalMutPointer {
    public typealias ConstPointer = SignalConstPointerFakeChatConnection

    public init(untyped: OpaquePointer?) {
        self.init(raw: untyped)
    }

    public func toOpaque() -> OpaquePointer? {
        self.raw
    }

    public func const() -> Self.ConstPointer {
        Self.ConstPointer(raw: self.raw)
    }
}

extension SignalConstPointerFakeChatConnection: SignalConstPointer {
    public func toOpaque() -> OpaquePointer? {
        self.raw
    }
}

extension SignalMutPointerFakeChatRemoteEnd: SignalMutPointer {
    public typealias ConstPointer = SignalConstPointerFakeChatRemoteEnd

    public init(untyped: OpaquePointer?) {
        self.init(raw: untyped)
    }

    public func toOpaque() -> OpaquePointer? {
        self.raw
    }

    public func const() -> Self.ConstPointer {
        Self.ConstPointer(raw: self.raw)
    }
}

extension SignalConstPointerFakeChatRemoteEnd: SignalConstPointer {
    public func toOpaque() -> OpaquePointer? {
        self.raw
    }
}

extension SignalMutPointerFakeChatSentRequest: SignalMutPointer {
    public typealias ConstPointer = SignalConstPointerFakeChatSentRequest

    public init(untyped: OpaquePointer?) {
        self.init(raw: untyped)
    }

    public func toOpaque() -> OpaquePointer? {
        self.raw
    }

    public func const() -> Self.ConstPointer {
        Self.ConstPointer(raw: self.raw)
    }
}

extension SignalConstPointerFakeChatSentRequest: SignalConstPointer {
    public func toOpaque() -> OpaquePointer? {
        self.raw
    }
}

extension SignalCPromiseMutPointerFakeChatSentRequest: PromiseStruct {
    typealias Result = SignalMutPointerFakeChatSentRequest
}

#endif
