import AppKit
import SwiftUI

struct AIChatView: View {
    @Bindable var viewModel: AIChatViewModel
    let onBackToRoot: () -> Void
    let onShowActions: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isListVisible {
                chatList
            } else {
                conversation
            }
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.ai")
    }

    private var chatList: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                GlassSearchField(
                    text: $viewModel.query,
                    focusRequest: viewModel.focusRequest,
                    placeholder: "Search Chats",
                    accessibilityLabel: "Search AI chats",
                    leadingInset: 58,
                    onSubmit: viewModel.performPrimaryAction
                )
                .frame(minHeight: 58)

                Button(action: onBackToRoot) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Yorozu")
                .padding(.leading, 2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider()
                .padding(.horizontal, 14)

            AIConversationList(viewModel: viewModel)
                .padding(.horizontal, 8)

            Divider()
                .padding(.horizontal, 14)

            HStack {
                Text(listFooterText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                footerButton(
                    shortcut: "⌘N",
                    title: "New Chat",
                    action: viewModel.beginNewChat
                )
                footerButton(
                    shortcut: "⌘K",
                    title: "Actions",
                    action: onShowActions
                )
            }
            .font(.footnote)
            .padding(.horizontal, 28)
            .frame(height: 42)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.ai.list")
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    viewModel.returnToList()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Chats")

                Text(viewModel.conversationTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Button(action: onShowActions) {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chat Actions")
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider()
                .padding(.horizontal, 14)

            AIConversationMessages(viewModel: viewModel)

            AIComposerView(
                viewModel: viewModel,
                onShowModelPicker: {
                    viewModel.beginChoosingModel()
                    onShowActions()
                }
            )
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.ai.conversation")
    }

    private var listFooterText: String {
        if let error = viewModel.errorMessage {
            return error
        }
        if let status = viewModel.statusMessage {
            return status
        }
        let count = viewModel.visibleConversations.count
        let countText = viewModel.listScope == .active
            ? "\(count) chats"
            : "\(count) archived chats"
        return "\(countText) · \(viewModel.providerDescriptor.displayName)"
    }

    private func footerButton(
        shortcut: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(shortcut)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(shortcut)")
    }
}

private struct AIConversationList: View {
    @Bindable var viewModel: AIChatViewModel
    @State private var hoveredID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.showsNewChatCommand {
                        row(
                            id: AIChatViewModel.newChatSelectionID,
                            title: "New Chat",
                            symbol: "square.and.pencil",
                            date: nil
                        )
                    }

                    ForEach(viewModel.visibleConversations) { conversation in
                        row(
                            id: conversation.id,
                            title: conversation.title,
                            symbol: conversation.deletionState == .failed
                                ? "exclamationmark.triangle"
                                : "bubble.left.and.bubble.right",
                            date: conversation.lastMessageAt
                        )
                    }

                    if viewModel.visibleConversations.isEmpty {
                        if !viewModel.query.isEmpty {
                            ContentUnavailableView {
                                Label("No Matching Chats", systemImage: "magnifyingglass")
                            }
                            .frame(minHeight: 260)
                        } else if viewModel.listScope == .archived {
                            ContentUnavailableView {
                                Label("No Archived Chats", systemImage: "archivebox")
                            }
                            .frame(minHeight: 260)
                        } else {
                            ContentUnavailableView {
                                Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text("Start a new chat with Yorozu AI.")
                            }
                            .frame(minHeight: 260)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.automatic)
            .onChange(of: viewModel.selectedListID) { _, selectedID in
                guard let selectedID else { return }
                proxy.scrollTo(selectedID, anchor: .center)
            }
        }
    }

    private func row(
        id: String,
        title: String,
        symbol: String,
        date: Date?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 16)

            if let date {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if viewModel.selectedListID == id {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
            } else if hoveredID == id {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quinary)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, 6)
        }
        .id(id)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ai.chat-row.\(id)")
        .onTapGesture(count: 2) {
            viewModel.selectListItem(id)
            viewModel.performPrimaryAction()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                viewModel.selectListItem(id)
            }
        )
        .onHover { hovering in
            hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID)
        }
        .accessibilityAddTraits(viewModel.selectedListID == id ? .isSelected : [])
        .accessibilityAction {
            viewModel.selectListItem(id)
            viewModel.performPrimaryAction()
        }
    }
}

private struct AIConversationMessages: View {
    @Bindable var viewModel: AIChatViewModel
    @State private var scrollState = AIConversationScrollState()
    @State private var autoScrollTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if viewModel.hasMoreMessages {
                        Button("Load Earlier Messages") {
                            viewModel.loadOlderMessages()
                        }
                        .frame(maxWidth: .infinity)
                        .onScrollVisibilityChange(threshold: 0.8) { isVisible in
                            if isVisible {
                                viewModel.loadOlderMessages()
                            }
                        }
                    }

                    if viewModel.messages.isEmpty, !viewModel.isLoadingConversation {
                        ContentUnavailableView {
                            Label("Start a Conversation", systemImage: "sparkles")
                        } description: {
                            Text("Ask a question or attach a file below.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 250)
                    }

                    ForEach(viewModel.messages) { message in
                        AIMessageView(
                            message: message,
                            onCopy: {
                                viewModel.copyMessage(message.text)
                            }
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("latest")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom <= 24
            } action: { _, atLatest in
                scrollState.updateGeometry(isAtLatest: atLatest)
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    scrollState.userInteractionDidBegin()
                    autoScrollTask?.cancel()
                    autoScrollTask = nil
                case .idle, .animating:
                    scrollState.userInteractionDidEnd()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let message = viewModel.errorMessage {
                    AIChatFloatingMessage(
                        message: message,
                        style: .error,
                        onDismiss: viewModel.dismissNotice
                    )
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                } else if let message = viewModel.statusMessage {
                    AIChatFloatingMessage(
                        message: message,
                        style: .status,
                        onDismiss: viewModel.dismissNotice
                    )
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                }
            }
            .overlay(alignment: .bottom) {
                if !scrollState.isAtLatest, !viewModel.messages.isEmpty {
                    Button {
                        scrollState.resetToLatest()
                        proxy.scrollTo("latest", anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .help("Jump to Latest")
                    .accessibilityLabel("Jump to Latest")
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: viewModel.messages.count) {
                scheduleAutoScroll(using: proxy)
            }
            .onChange(of: viewModel.messageContentRevision) {
                scheduleAutoScroll(using: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                guard streaming else { return }
                scheduleAutoScroll(using: proxy)
            }
            .onChange(of: viewModel.scrollToLatestRequest) {
                scrollState.resetToLatest()
                scheduleAutoScroll(
                    using: proxy,
                    delay: .milliseconds(20),
                    retryDelays: [.milliseconds(60), .milliseconds(140)]
                )
            }
            .onAppear {
                scrollState.resetToLatest()
                scheduleAutoScroll(
                    using: proxy,
                    delay: .milliseconds(20),
                    retryDelays: [.milliseconds(60), .milliseconds(140)]
                )
            }
            .onDisappear {
                autoScrollTask?.cancel()
                autoScrollTask = nil
            }
        }
    }

    private func scheduleAutoScroll(
        using proxy: ScrollViewProxy,
        delay: Duration = .milliseconds(16),
        retryDelays: [Duration] = []
    ) {
        guard scrollState.shouldFollowLatest,
              !scrollState.isUserInteracting else {
            return
        }
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            for currentDelay in [delay] + retryDelays {
                try? await Task.sleep(for: currentDelay)
                guard !Task.isCancelled,
                      scrollState.shouldFollowLatest,
                      !scrollState.isUserInteracting else {
                    autoScrollTask = nil
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
                scrollState.didScrollToLatest()
            }
            autoScrollTask = nil
        }
    }

}

struct AIConversationScrollState: Equatable {
    private(set) var isAtLatest = true
    private(set) var shouldFollowLatest = true
    private(set) var isUserInteracting = false

    mutating func updateGeometry(isAtLatest: Bool) {
        self.isAtLatest = isAtLatest
        if isAtLatest {
            shouldFollowLatest = true
        } else if isUserInteracting {
            shouldFollowLatest = false
        }
    }

    mutating func userInteractionDidBegin() {
        isUserInteracting = true
        if !isAtLatest {
            shouldFollowLatest = false
        }
    }

    mutating func userInteractionDidEnd() {
        isUserInteracting = false
    }

    mutating func resetToLatest() {
        isAtLatest = true
        shouldFollowLatest = true
        isUserInteracting = false
    }

    mutating func didScrollToLatest() {
        isAtLatest = true
    }
}

private struct AIChatFloatingMessage: View {
    enum Style: Equatable {
        case error
        case status

        var symbolName: String {
            switch self {
            case .error:
                "exclamationmark.triangle.fill"
            case .status:
                "info.circle.fill"
            }
        }
    }

    let message: String
    let style: Style
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbolName)
                .foregroundStyle(style == .error ? .orange : .secondary)

            Text(message)
                .font(.callout)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AIMessageView: View {
    let message: AIChatMessage
    let onCopy: () -> Void

    var body: some View {
        Group {
            if message.role == .user {
                userMessage
            } else {
                assistantMessage
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var userMessage: some View {
        AIUserMessageLayout(maximumWidthFraction: 0.8) {
            VStack(alignment: .trailing, spacing: 5) {
                VStack(alignment: .leading, spacing: 8) {
                    messageText
                    attachmentChips
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

                copyButton
            }
        }
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 9) {
            messageText
            attachmentChips
            citationLinks
            copyButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageText: some View {
        if message.isStreaming {
            Text(message.text.isEmpty ? "Thinking…" : message.text)
                .font(.body)
                .lineSpacing(message.role == .assistant ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            AIFormattedMessageText(
                blocks: AIChatMessageFormatter.blocks(
                    text: message.text,
                    citations: message.citations
                ),
                lineSpacing: message.role == .assistant ? 4 : 2,
                expandsHorizontally: message.role != .user
            )
        }
    }

    @ViewBuilder
    private var attachmentChips: some View {
        if !message.attachments.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(message.attachments) { attachment in
                    Label(
                        attachment.filename,
                        systemImage: attachment.kind == .image ? "photo" : "doc"
                    )
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quinary, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var citationLinks: some View {
        if !message.citations.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(message.citations) { citation in
                    Link(destination: citation.url) {
                        Label(citation.title, systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy Message")
        .accessibilityLabel("Copy Message")
    }
}

private struct AIFormattedMessageText: View {
    let blocks: [AIChatMessageBlock]
    let lineSpacing: CGFloat
    let expandsHorizontally: Bool

    @ViewBuilder
    var body: some View {
        if expandsHorizontally {
            blockList
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            blockList
        }
    }

    private var blockList: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: AIChatMessageBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inlineText(text)
                .font(.body)
                .lineSpacing(lineSpacing)

        case let .heading(level, text):
            inlineText(text)
                .font(level == 1 ? .title3.weight(.semibold) : .headline)
                .lineSpacing(lineSpacing)

        case let .unorderedListItem(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .frame(width: 12, alignment: .trailing)
                inlineText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .lineSpacing(lineSpacing)

        case let .orderedListItem(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .frame(minWidth: 20, alignment: .trailing)
                inlineText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .lineSpacing(lineSpacing)

        case let .quote(text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 2)
                inlineText(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(lineSpacing)
            }

        case let .code(language, content):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.automatic)
            }
            .padding(10)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

        case .separator:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return Text(attributed ?? AttributedString(source))
    }
}

private struct AIUserMessageLayout: Layout {
    let maximumWidthFraction: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let maximumWidth = proposal.width.map {
            $0 * min(max(maximumWidthFraction, 0), 1)
        }
        let size = subview.sizeThatFits(
            ProposedViewSize(width: maximumWidth, height: proposal.height)
        )
        return CGSize(
            width: proposal.width ?? size.width,
            height: size.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let maximumWidth = bounds.width * min(max(maximumWidthFraction, 0), 1)
        let size = subview.sizeThatFits(
            ProposedViewSize(width: maximumWidth, height: bounds.height)
        )
        subview.place(
            at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
            proposal: ProposedViewSize(size)
        )
    }
}

private struct AIComposerView: View {
    @Bindable var viewModel: AIChatViewModel
    let onShowModelPicker: () -> Void
    @State private var measuredTextHeight: CGFloat = 28

    private var composerTextHeight: CGFloat {
        min(max(measuredTextHeight, 28), 104)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !viewModel.attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(viewModel.attachments) { attachment in
                        HStack(spacing: 5) {
                            Image(systemName: attachment.kind == .image ? "photo" : "doc")
                            Text(attachment.filename)
                                .lineLimit(1)
                            Button {
                                viewModel.removeAttachment(id: attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(attachment.filename)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                if viewModel.providerDescriptor.capabilities.contains(.attachments) {
                    composerToolButton(
                        symbol: "paperclip",
                        title: "Attach Files",
                        action: viewModel.attachFiles
                    )
                }

                ZStack(alignment: .topLeading) {
                    AIComposerTextView(
                        text: $viewModel.prompt,
                        measuredHeight: $measuredTextHeight,
                        focusRequest: viewModel.composerFocusRequest,
                        onSend: viewModel.send
                    )
                    .frame(height: composerTextHeight)

                    if viewModel.prompt.isEmpty {
                        Text("Message Yorozu")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 7)
                            .padding(.top, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)

                if viewModel.providerDescriptor.capabilities.contains(.webSearch) {
                    composerToolButton(
                        symbol: "globe",
                        title: viewModel.enablesWebSearch
                            ? "Disable Web Search"
                            : "Enable Web Search",
                        isActive: viewModel.enablesWebSearch,
                        action: viewModel.toggleWebSearch
                    )
                }

                if viewModel.isSearchingWeb {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching the web")
                }

                Button(action: onShowModelPicker) {
                    HStack(spacing: 3) {
                        Text(viewModel.currentModel.title)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change Model")
                .accessibilityLabel("Change Model, \(viewModel.currentModel.title)")

                Button {
                    viewModel.isStreaming
                        ? viewModel.stopGenerating()
                        : viewModel.send()
                } label: {
                    Image(
                        systemName: viewModel.isStreaming
                            ? "stop.fill"
                            : "arrow.up"
                    )
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(
                        Color(nsColor: .windowBackgroundColor)
                    )
                    .background(.primary, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isStreaming && !viewModel.canSend)
                .opacity(
                    !viewModel.isStreaming && !viewModel.canSend
                        ? 0.35
                        : 1
                )
                .accessibilityLabel(viewModel.isStreaming ? "Stop" : "Send")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func composerToolButton(
        symbol: String,
        title: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? .primary : .secondary)
                .background(
                    isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct AIComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let focusRequest: Int
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            measuredHeight: $measuredHeight,
            onSend: onSend
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 7, height: 4)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityIdentifier("ai.composer")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.onSend = onSend
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.scheduleHeightUpdate()
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var measuredHeight: CGFloat
        weak var textView: NSTextView?
        var onSend: () -> Void
        var lastFocusRequest = -1

        init(
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            onSend: @escaping () -> Void
        ) {
            _text = text
            _measuredHeight = measuredHeight
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            scheduleHeightUpdate()
        }

        func scheduleHeightUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateMeasuredHeight()
            }
        }

        private func updateMeasuredHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            let resolvedHeight = max(28, ceil(contentHeight))
            textView.enclosingScrollView?.hasVerticalScroller = resolvedHeight > 104
            guard abs(measuredHeight - resolvedHeight) > 0.5 else { return }
            measuredHeight = resolvedHeight
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  !textView.hasMarkedText() else {
                return false
            }
            let modifiers = NSApp.currentEvent?.modifierFlags
                .intersection(.deviceIndependentFlagsMask) ?? []
            guard !modifiers.contains(.shift) else { return false }
            onSend()
            return true
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(
            proposal: proposal,
            subviews: subviews,
            place: nil
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        _ = layout(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
        ) { point, size, subview in
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews,
        place: ((CGPoint, CGSize, LayoutSubview) -> Void)?
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var point = CGPoint.zero
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > 0, point.x + size.width > maximumWidth {
                point.x = 0
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            place?(point, size, subview)
            usedWidth = max(usedWidth, point.x + size.width)
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: usedWidth, height: point.y + rowHeight)
    }
}
