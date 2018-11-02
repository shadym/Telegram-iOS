import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

private enum PeerMessagesMediaPlaylistLoadAnchor {
    case messageId(MessageId)
    case index(MessageIndex)
}

private enum PeerMessagesMediaPlaylistNavigation {
    case earlier
    case later
    case random
}

struct MessageMediaPlaylistItemStableId: Hashable {
    let stableId: UInt32
    
    var hashValue: Int {
        return self.stableId.hashValue
    }
    
    static func ==(lhs: MessageMediaPlaylistItemStableId, rhs: MessageMediaPlaylistItemStableId) -> Bool {
        return lhs.stableId == rhs.stableId
    }
}

struct PeerMessagesMediaPlaylistItemId: SharedMediaPlaylistItemId {
    let messageId: MessageId
    
    func isEqual(to: SharedMediaPlaylistItemId) -> Bool {
        if let to = to as? PeerMessagesMediaPlaylistItemId {
            if self.messageId != to.messageId {
                return false
            }
            return true
        }
        return false
    }
}

private func extractFileMedia(_ message: Message) -> TelegramMediaFile? {
    var file: TelegramMediaFile?
    for media in message.media {
        if let media = media as? TelegramMediaFile {
            file = media
            break
        } else if let media = media as? TelegramMediaWebpage, case let .Loaded(content) = media.content, let f = content.file {
            file = f
            break
        }
    }
    return file
}

final class MessageMediaPlaylistItem: SharedMediaPlaylistItem {
    let id: SharedMediaPlaylistItemId
    let message: Message
    
    init(message: Message) {
        self.id = PeerMessagesMediaPlaylistItemId(messageId: message.id)
        self.message = message
    }
    
    var stableId: AnyHashable {
        return MessageMediaPlaylistItemStableId(stableId: message.stableId)
    }
    
    var playbackData: SharedMediaPlaybackData? {
        if let file = extractFileMedia(self.message) {
            let fileReference = FileMediaReference.message(message: MessageReference(self.message), media: file)
            let source = SharedMediaPlaybackDataSource.telegramFile(fileReference)
            for attribute in file.attributes {
                switch attribute {
                    case let .Audio(isVoice, _, _, _, _):
                        if isVoice {
                            return SharedMediaPlaybackData(type: .voice, source: source)
                        } else {
                            return SharedMediaPlaybackData(type: .music, source: source)
                        }
                    case let .Video(_, _, flags):
                        if flags.contains(.instantRoundVideo) {
                            return SharedMediaPlaybackData(type: .instantVideo, source: source)
                        } else {
                            return nil
                        }
                    default:
                        break
                }
            }
            if file.mimeType.hasPrefix("audio/") {
                return SharedMediaPlaybackData(type: .music, source: source)
            }
            if let fileName = file.fileName {
                let ext = (fileName as NSString).pathExtension.lowercased()
                if ext == "wav" || ext == "opus" {
                    return SharedMediaPlaybackData(type: .music, source: source)
                }
            }
        }
        return nil
    }

    var displayData: SharedMediaPlaybackDisplayData? {
        if let file = extractFileMedia(self.message) {
            for attribute in file.attributes {
                switch attribute {
                    case let .Audio(isVoice, _, title, performer, _):
                        if isVoice {
                            return SharedMediaPlaybackDisplayData.voice(author: self.message.author, peer: self.message.peers[self.message.id.peerId])
                        } else {
                            var updatedTitle = title
                            let updatedPerformer = performer
                            if (title ?? "").isEmpty && (performer ?? "").isEmpty {
                                updatedTitle = file.fileName ?? ""
                            }
                            return SharedMediaPlaybackDisplayData.music(title: updatedTitle, performer: updatedPerformer, albumArt: SharedMediaPlaybackAlbumArt(thumbnailResource: ExternalMusicAlbumArtResource(title: title ?? "", performer: performer ?? "", isThumbnail: true), fullSizeResource: ExternalMusicAlbumArtResource(title: updatedTitle ?? "", performer: updatedPerformer ?? "", isThumbnail: false)))
                        }
                    case let .Video(_, _, flags):
                        if flags.contains(.instantRoundVideo) {
                            return SharedMediaPlaybackDisplayData.instantVideo(author: self.message.author, peer: self.message.peers[self.message.id.peerId], timestamp: self.message.timestamp)
                        } else {
                            return nil
                        }
                    default:
                        break
                }
            }
            
            return SharedMediaPlaybackDisplayData.music(title: file.fileName ?? "", performer: self.message.author?.displayTitle ?? "", albumArt: nil)
        }
        return nil
    }
}

private enum NavigatedMessageFromViewPosition {
    case later
    case earlier
    case exact
}

private func navigatedMessageFromView(_ view: MessageHistoryView, anchorIndex: MessageIndex, position: NavigatedMessageFromViewPosition) -> (message: Message, around: [Message], exact: Bool)? {
    var index = 0
    for entry in view.entries {
        if entry.index.id == anchorIndex.id {
            switch position {
                case .exact:
                    switch entry {
                        case let .MessageEntry(message, _, _, _):
                            return (message, [], true)
                        default:
                            return nil
                    }
                case .later:
                    if index + 1 < view.entries.count {
                        switch view.entries[index + 1] {
                            case let .MessageEntry(message, _, _, _):
                                return (message, [], true)
                            default:
                                return nil
                        }
                    } else {
                        return nil
                    }
                case .earlier:
                    if index != 0 {
                        switch view.entries[index - 1] {
                            case let .MessageEntry(message, _, _, _):
                                return (message, [], true)
                            default:
                                return nil
                        }
                    } else {
                        return nil
                    }
            }
        }
        index += 1
    }
    if !view.entries.isEmpty {
        switch position {
            case .later, .exact:
                switch view.entries[view.entries.count - 1] {
                    case let .MessageEntry(message, _, _, _):
                        return (message, [], false)
                    default:
                        return nil
                }
            case .earlier:
                switch view.entries[0] {
                    case let .MessageEntry(message, _, _, _):
                        return (message, [], false)
                    default:
                        return nil
                }
        }
    } else {
        return nil
    }
}

enum PeerMessagesPlaylistLocation: Equatable, SharedMediaPlaylistLocation {
    case messages(peerId: PeerId, tagMask: MessageTags, at: MessageId)
    case singleMessage(MessageId)
    case recentActions(Message)

    var playlistId: PeerMessagesMediaPlaylistId {
        switch self {
            case let .messages(peerId, _, _):
                return .peer(peerId)
            case let .singleMessage(id):
                return .peer(id.peerId)
            case let .recentActions(message):
                return .recentActions(message.id.peerId)
        }
    }
    
    func isEqual(to: SharedMediaPlaylistLocation) -> Bool {
        if let to = to as? PeerMessagesPlaylistLocation {
            return self == to
        } else {
            return false
        }
    }
    
    static func ==(lhs: PeerMessagesPlaylistLocation, rhs: PeerMessagesPlaylistLocation) -> Bool {
        switch lhs {
            case let .messages(peerId, tagMask, at):
                if case .messages(peerId, tagMask, at) = rhs {
                    return true
                } else {
                    return false
                }
            case let .singleMessage(messageId):
                if case .singleMessage(messageId) = rhs {
                    return true
                } else {
                    return false
                }
            case let .recentActions(lhsMessage):
                if case let .recentActions(rhsMessage) = rhs, lhsMessage.id == rhsMessage.id {
                    return true
                } else {
                    return false
                }
        }
    }
}

enum PeerMessagesMediaPlaylistId: Equatable, SharedMediaPlaylistId {
    case peer(PeerId)
    case recentActions(PeerId)
    
    func isEqual(to: SharedMediaPlaylistId) -> Bool {
        if let to = to as? PeerMessagesMediaPlaylistId {
            return self == to
        }
        return false
    }
}
    
func peerMessageMediaPlayerType(_ message: Message) -> MediaManagerPlayerType? {
    if let file = extractFileMedia(message) {
        if file.isVoice || file.isInstantVideo {
            return .voice
        } else if file.isMusic {
            return .music
        }
    }
    return nil
}
    
func peerMessagesMediaPlaylistAndItemId(_ message: Message, isRecentActions: Bool) -> (SharedMediaPlaylistId, SharedMediaPlaylistItemId)? {
    if isRecentActions {
        return (PeerMessagesMediaPlaylistId.recentActions(message.id.peerId), PeerMessagesMediaPlaylistItemId(messageId: message.id))
    } else {
        return (PeerMessagesMediaPlaylistId.peer(message.id.peerId), PeerMessagesMediaPlaylistItemId(messageId: message.id))
    }
}

final class PeerMessagesMediaPlaylist: SharedMediaPlaylist {
    private let postbox: Postbox
    private let network: Network
    private let messagesLocation: PeerMessagesPlaylistLocation
    
    var location: SharedMediaPlaylistLocation {
        return self.messagesLocation
    }
    
    private let navigationDisposable = MetaDisposable()
    
    private var currentItem: (current: Message, around: [Message])?
    private var loadingItem: Bool = false
    private var playedToEnd: Bool = false
    private var order: MusicPlaybackSettingsOrder = .regular
    private(set) var looping: MusicPlaybackSettingsLooping = .none
    
    let id: SharedMediaPlaylistId
    
    private let stateValue = Promise<SharedMediaPlaylistState>()
    var state: Signal<SharedMediaPlaylistState, NoError> {
        return self.stateValue.get()
    }
    
    init(postbox: Postbox, network: Network, location: PeerMessagesPlaylistLocation) {
        assert(Queue.mainQueue().isCurrent())
        
        self.id = location.playlistId
        
        self.postbox = postbox
        self.network = network
        self.messagesLocation = location
        
        switch self.messagesLocation {
            case let .messages(_, _, messageId):
                self.loadItem(anchor: .messageId(messageId), navigation: .later)
            case let .singleMessage(messageId):
                self.loadItem(anchor: .messageId(messageId), navigation: .later)
            case let .recentActions(message):
                self.loadingItem = false
                self.currentItem = (message, [])
                self.updateState()
        }
    }
    
    deinit {
        self.navigationDisposable.dispose()
    }
    
    func control(_ action: SharedMediaPlaylistControlAction) {
        assert(Queue.mainQueue().isCurrent())
        
        switch action {
            case .next, .previous:
                switch self.messagesLocation {
                    case .recentActions:
                        self.loadingItem = false
                        self.currentItem = nil
                        self.updateState()
                        return
                    default:
                        break
                }
                if !self.loadingItem {
                    if let currentItem = self.currentItem {
                        let navigation: PeerMessagesMediaPlaylistNavigation
                        switch self.order {
                            case .regular:
                                if case .next = action {
                                    navigation = .earlier
                                } else {
                                    navigation = .later
                                }
                            case .reversed:
                                if case .next = action {
                                    navigation = .later
                                } else {
                                    navigation = .earlier
                                }
                            case .random:
                                navigation = .random
                        }
                        
                        if case .singleMessage = self.messagesLocation {
                            self.loadingItem = false
                            self.currentItem = nil
                            self.updateState()
                        } else {
                             self.loadItem(anchor: .index(MessageIndex(currentItem.current)), navigation: navigation)
                        }
                    }
                }
        }
    }
    
    func setOrder(_ order: MusicPlaybackSettingsOrder) {
        if self.order != order {
            self.order = order
            self.updateState()
        }
    }
    
    func setLooping(_ looping: MusicPlaybackSettingsLooping) {
        if self.looping != looping {
            self.looping = looping
            self.updateState()
        }
    }
    
    private func updateState() {
        var item: MessageMediaPlaylistItem?
        var nextItem: MessageMediaPlaylistItem?
        var previousItem: MessageMediaPlaylistItem?
        if let (message, aroundMessages) = self.currentItem {
            item = MessageMediaPlaylistItem(message: message)
            for around in aroundMessages {
                if MessageIndex(around) < MessageIndex(message) {
                    previousItem = MessageMediaPlaylistItem(message: around)
                } else {
                    nextItem = MessageMediaPlaylistItem(message: around)
                }
            }
        }
        self.stateValue.set(.single(SharedMediaPlaylistState(loading: self.loadingItem, playedToEnd: self.playedToEnd, item: item, nextItem: nextItem, previousItem: previousItem, order: self.order, looping: self.looping)))
    }
    
    private func loadItem(anchor: PeerMessagesMediaPlaylistLoadAnchor, navigation: PeerMessagesMediaPlaylistNavigation) {
        self.loadingItem = true
        self.updateState()
        switch anchor {
            case let .messageId(messageId):
                self.navigationDisposable.set((self.postbox.messageAtId(messageId)
                |> take(1)
                |> deliverOnMainQueue).start(next: { [weak self] message in
                    if let strongSelf = self {
                        assert(strongSelf.loadingItem)
                        
                        strongSelf.loadingItem = false
                        if let message = message {
                            strongSelf.currentItem = (message, [])
                        } else {
                            strongSelf.currentItem = nil
                        }
                        strongSelf.updateState()
                    }
                }))
            case let .index(index):
                switch self.messagesLocation {
                    case let .messages(peerId, tagMask, _):
                        let inputIndex: Signal<MessageIndex, NoError>
                        let looping = self.looping
                        switch self.order {
                            case .regular, .reversed:
                                inputIndex = .single(index)
                            case .random:
                                inputIndex = self.postbox.transaction { transaction -> MessageIndex in
                                    return transaction.findRandomMessage(peerId: peerId, tagMask: tagMask, ignoreId: index.id) ?? index
                                }
                        }
                        let historySignal = inputIndex
                        |> mapToSignal { inputIndex -> Signal<(Message, [Message])?, NoError> in
                            return self.postbox.aroundMessageHistoryViewForLocation(.peer(peerId), index: .message(inputIndex), anchorIndex: .message(inputIndex), count: 10, clipHoles: false, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tagMask: tagMask, orderStatistics: [])
                            |> mapToSignal { view -> Signal<(Message, [Message])?, NoError> in
                                let position: NavigatedMessageFromViewPosition
                                switch navigation {
                                    case .later:
                                        position = .later
                                    case .earlier:
                                        position = .earlier
                                    case .random:
                                        position = .exact
                                }
                                
                                if let (message, aroundMessages, exact) = navigatedMessageFromView(view.0, anchorIndex: inputIndex, position: position) {
                                    switch navigation {
                                        case .random:
                                            return .single((message, []))
                                        default:
                                            if exact {
                                                return .single((message, aroundMessages))
                                            }
                                    }
                                }
                                
                                if case .all = looping {
                                    let viewIndex: MessageHistoryAnchorIndex
                                    if case .earlier = navigation {
                                        viewIndex = .upperBound
                                    } else {
                                        viewIndex = .lowerBound
                                    }
                                    return self.postbox.aroundMessageHistoryViewForLocation(.peer(peerId), index: viewIndex, anchorIndex: viewIndex, count: 10, clipHoles: false, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tagMask: tagMask, orderStatistics: [])
                                    |> mapToSignal { view -> Signal<(Message, [Message])?, NoError> in
                                        let position: NavigatedMessageFromViewPosition
                                        switch navigation {
                                            case .later, .random:
                                                position = .earlier
                                            case .earlier:
                                                position = .later
                                        }
                                        if let (message, aroundMessages, _) = navigatedMessageFromView(view.0, anchorIndex: MessageIndex.absoluteLowerBound(), position: position) {
                                            return .single((message, aroundMessages))
                                        } else {
                                            return .single(nil)
                                        }
                                    }
                                } else {
                                    return .single(nil)
                                }
                            }
                        }
                        |> take(1)
                        |> deliverOnMainQueue
                        self.navigationDisposable.set(historySignal.start(next: { [weak self] messageAndAroundMessages in
                            if let strongSelf = self {
                                assert(strongSelf.loadingItem)
                                
                                strongSelf.loadingItem = false
                                if let (message, aroundMessages) = messageAndAroundMessages {
                                    strongSelf.currentItem = (message, aroundMessages)
                                    strongSelf.playedToEnd = false
                                } else {
                                    strongSelf.playedToEnd = true
                                }
                                strongSelf.updateState()
                            }
                        }))
                    case .singleMessage:
                        self.navigationDisposable.set((self.postbox.messageAtId(index.id)
                        |> take(1)
                        |> deliverOnMainQueue).start(next: { [weak self] message in
                            if let strongSelf = self {
                                assert(strongSelf.loadingItem)
                                
                                strongSelf.loadingItem = false
                                if let message = message {
                                    strongSelf.currentItem = (message, [])
                                } else {
                                    strongSelf.currentItem = nil
                                }
                                strongSelf.updateState()
                            }
                        }))
                    case let .recentActions(message):
                        self.loadingItem = false
                        self.currentItem = (message, [])
                        self.updateState()
            }
        }
    }
    
    func onItemPlaybackStarted(_ item: SharedMediaPlaylistItem) {
        if let item = item as? MessageMediaPlaylistItem {
            switch self.messagesLocation {
                case .recentActions:
                    return
                default:
                    break
            }
            let _ = markMessageContentAsConsumedInteractively(postbox: self.postbox, messageId: item.message.id).start()
        }
    }
}
