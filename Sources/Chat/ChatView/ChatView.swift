//
//  ChatView.swift
//  Chat
//
//  Created by Alisa Mylnikova on 20.04.2022.
//

import SwiftUI
import MediaPicker

public struct ChatView<MessageContent: View, InputViewContent: View>: View {

    /// To build a custom message view use the following parameters passed by this closure:
    /// - message containing user, attachments, etc.
    /// - position of message in its continuous group of messages from the same user
    /// - pass attachment to this closure to use ChatView's fullscreen media viewer
    public typealias MessageBuilderClosure = ((Message, PositionInGroup, @escaping (any Attachment) -> Void) -> MessageContent)

    public typealias InputViewBuilderClosure = ((
        Binding<String>, InputViewAttachments, InputViewState, InputViewStyle, @escaping (InputViewAction) -> Void) -> InputViewContent)

    @Environment(\.chatTheme) private var theme
    @Environment(\.mediaPickerTheme) private var pickerTheme

    let didSendMessage: (DraftMessage) -> Void

    /// provide custom message view builder
    var messageBuilder: MessageBuilderClosure? = nil

    /// provide custom input view builder
    var inputViewBuilder: InputViewBuilderClosure? = nil

    var avatarSize: CGFloat = 32
    var assetsPickerLimit: Int = 10
    var messageUseMarkdown: Bool = false
    var chatTitle: String?

    private let sections: [MessagesSection]
    private let ids: [String]

    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var inputViewModel = InputViewModel()
    @StateObject private var globalFocusState = GlobalFocusState()
    @StateObject private var paginationState = PaginationState()

    @State private var showScrollToBottom: Bool = false

    public init(messages: [Message],
                didSendMessage: @escaping (DraftMessage) -> Void,
                messageBuilder: @escaping MessageBuilderClosure,
                inputViewBuilder: @escaping InputViewBuilderClosure) {
        self.didSendMessage = didSendMessage
        self.sections = ChatView.mapMessages(messages)
        self.ids = messages.map { $0.id }
        self.messageBuilder = messageBuilder
        self.inputViewBuilder = inputViewBuilder
    }

    public var body: some View {
        VStack {
            ZStack(alignment: .bottomTrailing) {
                list

                if showScrollToBottom {
                    Button {
                        NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
                    } label: {
                        theme.images.scrollToBottom
                            .frame(width: 40, height: 40)
                            .circleBackground(theme.colors.friendMessage)
                    }
                    .padding(8)
                }
            }

            Group {
                if let inputViewBuilder = inputViewBuilder {
                    inputViewBuilder($inputViewModel.attachments.text, inputViewModel.attachments, inputViewModel.state, .message, inputViewModel.inputViewAction())
                } else {
                    InputView(
                        viewModel: inputViewModel,
                        style: .message
                    )
                }
            }
            .environmentObject(globalFocusState)
            .onAppear(perform: inputViewModel.onStart)
            .onDisappear(perform: inputViewModel.onStop)
        }
        .fullScreenCover(isPresented: $viewModel.fullscreenAttachmentPresented) {
            let attachments = sections.flatMap { section in section.rows.flatMap { $0.message.attachments } }
            let index = attachments.firstIndex { $0.id == viewModel.fullscreenAttachmentItem?.id }

            AttachmentsPages(
                viewModel: AttachmentsPagesViewModel(
                    attachments: attachments,
                    index: index ?? 0
                ),
                onClose: { [weak viewModel] in
                    viewModel?.dismissAttachmentFullScreen()
                }
            )
        }
        .fullScreenCover(isPresented: $inputViewModel.showPicker) {
            AttachmentsEditor(inputViewModel: inputViewModel, inputViewBuilder: inputViewBuilder, assetsPickerLimit: assetsPickerLimit, chatTitle: chatTitle)
                .environmentObject(globalFocusState)
        }
        .onChange(of: inputViewModel.showPicker) {
            if $0 {
                globalFocusState.focus = nil
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    var list: some View {
        UIList(viewModel: viewModel,
               paginationState: paginationState,
               showScrollToBottom: $showScrollToBottom,
               messageBuilder: messageBuilder,
               avatarSize: avatarSize,
               messageUseMarkdown: messageUseMarkdown,
               sections: sections,
               ids: ids
        )
        .onTapGesture {
            globalFocusState.focus = nil
        }
        .onAppear {
            viewModel.didSendMessage = didSendMessage
            inputViewModel.didSendMessage = { value in
                didSendMessage(value)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
                }
            }
        }
    }
}

private extension ChatView {
    static func mapMessages(_ messages: [Message]) -> [MessagesSection] {
        let dates = Set(messages.map({ $0.createdAt.startOfDay() }))
            .sorted()
            .reversed()
        var result: [MessagesSection] = []

        for date in dates {
            let section = MessagesSection(
                date: date,
                rows: wrapMessages(messages.filter({ $0.createdAt.isSameDay(date) }))
            )
            result.append(section)
        }

        return result
    }

    static func wrapMessages(_ messages: [Message]) -> [MessageRow] {
        messages
            .enumerated()
            .map {
                let nextMessageExists = messages[safe: $0.offset + 1] != nil
                let nextMessageIsSameUser = messages[safe: $0.offset + 1]?.user.id == $0.element.user.id
                let prevMessageIsSameUser = messages[safe: $0.offset - 1]?.user.id == $0.element.user.id

                let position: PositionInGroup
                if nextMessageExists, nextMessageIsSameUser, prevMessageIsSameUser {
                    position = .middle
                } else if !nextMessageExists || !nextMessageIsSameUser, !prevMessageIsSameUser {
                    position = .single
                } else if nextMessageExists, nextMessageIsSameUser {
                    position = .first
                } else {
                    position = .last
                }

                return MessageRow(message: $0.element, positionInGroup: position)
            }
            .reversed()
    }
}

public extension ChatView {

    func avatarSize(avatarSize: CGFloat) -> ChatView {
        var view = self
        view.avatarSize = avatarSize
        return view
    }

    func messageUseMarkdown(messageUseMarkdown: Bool) -> ChatView {
        var view = self
        view.messageUseMarkdown = messageUseMarkdown
        return view
    }

    func assetsPickerLimit(assetsPickerLimit: Int) -> ChatView {
        var view = self
        view.assetsPickerLimit = assetsPickerLimit
        return view
    }

    /// when user scrolls to `offset`-th meassage from the end, call the handler function, so user can load more messages
    func enableLoadMore(offset: Int = 0, handler: @escaping ChatPaginationClosure) -> ChatView {
        var view = self
        view._paginationState = StateObject(wrappedValue: PaginationState(onEvent: handler, offset: offset))
        return view
    }

    func chatNavigation(title: String, status: String? = nil, cover: URL? = nil) -> some View {
        var view = self
        view.chatTitle = title
        return view.modifier(ChatNavigationModifier(title: title, status: status, cover: cover))
    }
}

public extension ChatView where MessageContent == EmptyView {

    init(messages: [Message],
         didSendMessage: @escaping (DraftMessage) -> Void,
         inputViewBuilder: @escaping InputViewBuilderClosure) {
        self.didSendMessage = didSendMessage
        self.sections = ChatView.mapMessages(messages)
        self.ids = messages.map { $0.id }
        self.inputViewBuilder = inputViewBuilder
    }
}

public extension ChatView where InputViewContent == EmptyView {

    init(messages: [Message],
         didSendMessage: @escaping (DraftMessage) -> Void,
         messageBuilder: @escaping MessageBuilderClosure) {
        self.didSendMessage = didSendMessage
        self.sections = ChatView.mapMessages(messages)
        self.ids = messages.map { $0.id }
        self.messageBuilder = messageBuilder
    }
}

public extension ChatView where MessageContent == EmptyView, InputViewContent == EmptyView {

    init(messages: [Message],
         didSendMessage: @escaping (DraftMessage) -> Void) {
        self.didSendMessage = didSendMessage
        self.sections = ChatView.mapMessages(messages)
        self.ids = messages.map { $0.id }
    }
}
