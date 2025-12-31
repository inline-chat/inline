# Non-bubble message view (Mac) — change plan + patches

## High-level summary
- Add a feature flag (`enableNonBubbleMessages`) in `AppSettings` and surface it in Experimental settings.
- Thread a new `isNonBubble` flag through `MessageViewInputProps`/`MessageViewProps` and the message list builder.
- Update `MessageViewAppKit` for non-bubble layout: neutral colors, no bubble background, left alignment, and hover-driven time/state visibility.
- Adjust `MessageSizeCalculator` to compute sizes/spacing without bubble insets and with smaller media max size.
- Tweak `MessageTimeAndState` to support neutral coloring when not in bubble mode.

## Files that need changes
- `apple/InlineMac/Views/Settings/AppSettings.swift`
- `apple/InlineMac/Views/Settings/Views/ExperimentalSettingsDetailView.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/Message/MessageViewTypes.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MessageTimeAndState.swift`
- `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`

## Call sites that need change
- `MessageTimeAndState` initialization/update
  - `apple/InlineMac/Views/Message/MessageView.swift:229` — init: add `useNeutralStyle: isNonBubble`
  - `apple/InlineMac/Views/Message/MessageView.swift:1774` — update: add `useNeutralStyle: isNonBubble`
- `MessageViewProps` creation
  - `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1347` — add `isNonBubble: useNonBubbleMessages`
  - `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1678` — add `isNonBubble: useNonBubbleMessages`
- `MessageViewInputProps` creation
  - `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1412` — add `isNonBubble: useNonBubbleMessages`
  - `apple/InlineMac/Views/MessageList/MessageListAppKit.swift:1423` — add `isNonBubble: useNonBubbleMessages`

## Patches (apply as-is)

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/Message/MessageTimeAndState.swift
@@
   private var trackingArea: NSTrackingArea?
 
   private var isOverlay: Bool
+  private var useNeutralStyle: Bool
 
   private var textColor: NSColor {
     if isOverlay {
       .white.withAlphaComponent(0.8)
+    } else if useNeutralStyle {
+      .tertiaryLabelColor
     } else {
       fullMessage.message.out == true ? .white.withAlphaComponent(0.7) : .tertiaryLabelColor
     }
   }
@@
     let scaleFactor: CGFloat
     let isOutgoing: Bool
     let isOverlay: Bool
+    let useNeutralStyle: Bool
     let isDarkMode: Bool
   }
@@
       scaleFactor: scale,
       isOutgoing: fullMessage.message.out ?? false,
       isOverlay: isOverlay,
+      useNeutralStyle: useNeutralStyle,
       isDarkMode: NSApp.effectiveAppearance.isDarkMode
     )
@@
-  init(fullMessage: FullMessage, overlay: Bool) {
+  init(fullMessage: FullMessage, overlay: Bool, useNeutralStyle: Bool = false) {
     self.fullMessage = fullMessage
     isOverlay = overlay
+    self.useNeutralStyle = useNeutralStyle
     super.init(frame: .zero)
     configureLayerSetup()
     updateContent()
@@
-  public func updateMessage(_ fullMessage: FullMessage, overlay: Bool) {
+  public func updateMessage(_ fullMessage: FullMessage, overlay: Bool, useNeutralStyle: Bool = false) {
     let oldStatus = self.fullMessage.message.status
     let oldDate = self.fullMessage.message.date
     let oldOut = self.fullMessage.message.out
     let oldIsOverlay = isOverlay
+    let oldNeutralStyle = useNeutralStyle
 
     self.fullMessage = fullMessage
     isOverlay = overlay
+    self.useNeutralStyle = useNeutralStyle
@@
-    if fullMessage.message.out != oldOut {
+    if fullMessage.message.out != oldOut || oldNeutralStyle != useNeutralStyle {
       updateColorStyles()
     }
*** End Patch
```

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/Message/MessageView.swift
@@
   private var isDM: Bool {
     props.isDM
   }
 
+  private var isNonBubble: Bool {
+    props.isNonBubble
+  }
+
   private var chatHasAvatar: Bool {
-    !isDM
+    isNonBubble || !isDM
   }
@@
   private var showsAvatar: Bool {
-    chatHasAvatar && props.layout.hasAvatar && !outgoing
+    chatHasAvatar && props.layout.hasAvatar && (isNonBubble || !outgoing)
   }
@@
   private var textColor: NSColor {
-    Self.textColor(outgoing: outgoing)
+    if isNonBubble {
+      NSColor.labelColor
+    } else {
+      Self.textColor(outgoing: outgoing)
+    }
   }
@@
   private var bubbleBackgroundColor: NSColor {
-    if !props.layout.hasBubbleColor {
+    if isNonBubble || !props.layout.hasBubbleColor {
       NSColor.clear
     } else if outgoing {
       Theme.messageBubblePrimaryBgColor
@@
   private var linkColor: NSColor {
-    Self.linkColor(outgoing: outgoing)
+    if isNonBubble {
+      NSColor.linkColor
+    } else {
+      Self.linkColor(outgoing: outgoing)
+    }
   }
@@
   private var isTimeOverlay: Bool {
+    if isNonBubble {
+      return false
+    }
     // If we have a document and the message is empty, we don't want to show the time overlay
     if props.layout.hasDocument, !props.layout.hasText {
-      false
+      return false
     } else if emojiMessage {
-      true
+      return true
     } else {
       // for photos, we want to show the time overlay if the message is empty
-      !props.layout.hasText
+      return !props.layout.hasText
     }
   }
@@
   private lazy var timeAndStateView: MessageTimeAndState = {
-    let view = MessageTimeAndState(fullMessage: fullMessage, overlay: isTimeOverlay)
+    let view = MessageTimeAndState(
+      fullMessage: fullMessage,
+      overlay: isTimeOverlay,
+      useNeutralStyle: isNonBubble
+    )
     view.translatesAutoresizingMaskIntoConstraints = false
     view.wantsLayer = true
     return view
   }()
@@
     addSubview(timeAndStateView)
 
+    if isNonBubble {
+      addHoverTrackingArea()
+      updateTimeAndStateVisibility(animated: false)
+    }
+
     setupMessageText()
     setupContextMenu()
     setupGestureRecognizers()
@@
+    let sidePadding = Theme.messageSidePadding
+    let contentLeading = chatHasAvatar ? layout.nameAndBubbleLeading : sidePadding
+
     if let name = layout.name, showsName {
+      let nameLeading = isNonBubble
+        ? contentLeading + (layout.text?.spacing.left ?? 0)
+        : layout.nameAndBubbleLeading + name.spacing.left
       constraints.append(
         contentsOf: [
           nameLabel.leadingAnchor
             .constraint(
               equalTo: leadingAnchor,
-              constant: layout.nameAndBubbleLeading + name.spacing.left
+              constant: nameLeading
             ),
@@
     contentViewWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: layout.bubble.size.width)
     contentViewHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: layout.bubble.size.height)
 
-    let sidePadding = Theme.messageSidePadding
-    let contentLeading = chatHasAvatar ? layout.nameAndBubbleLeading : sidePadding
-
     // Depending on outgoing or incoming message
-    let contentViewSideAnchor =
-      !outgoing ?
-      contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading) :
-      contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding)
-    let bubbleViewSideAnchor =
-      !outgoing ?
-      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading) :
-      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding)
+    let alignLeading = isNonBubble || !outgoing
+    let contentViewSideAnchor =
+      alignLeading ?
+      contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading) :
+      contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding)
+    let bubbleViewSideAnchor =
+      alignLeading ?
+      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading) :
+      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding)
@@
       constraints.append(
         contentsOf: [
           timeAndStateView.widthAnchor.constraint(equalToConstant: time.size.width),
           timeAndStateView.heightAnchor.constraint(
             equalToConstant: time.size.height
           ),
-        ]
-      )
-
-      constraints.append(contentsOf: [
-        timeAndStateView.trailingAnchor
-          .constraint(
-            equalTo: bubbleView.trailingAnchor,
-            constant: -time.spacing.right
-          ),
-        timeAndStateView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -time.spacing.bottom),
-      ])
+        ]
+      )
+
+      if isNonBubble {
+        let timeTopOffset = layout.hasText ? layout.textContentViewTop : layout.topMostContentTopSpacing
+        timeViewTopConstraint = timeAndStateView.topAnchor.constraint(
+          equalTo: contentView.topAnchor,
+          constant: timeTopOffset
+        )
+        constraints.append(contentsOf: [
+          timeViewTopConstraint!,
+          timeAndStateView.trailingAnchor.constraint(
+            equalTo: trailingAnchor,
+            constant: -Theme.messageSidePadding
+          ),
+        ])
+      } else {
+        constraints.append(contentsOf: [
+          timeAndStateView.trailingAnchor
+            .constraint(
+              equalTo: bubbleView.trailingAnchor,
+              constant: -time.spacing.right
+            ),
+          timeAndStateView.bottomAnchor.constraint(
+            equalTo: bubbleView.bottomAnchor,
+            constant: -time.spacing.bottom
+          ),
+        ])
+      }
     }
@@
   private var bubbleViewWidthConstraint: NSLayoutConstraint!
   private var bubbleViewHeightConstraint: NSLayoutConstraint!
 
+  private var timeViewTopConstraint: NSLayoutConstraint?
+
   private var isInitialUpdateConstraint = true
@@
     }
+
+    if isNonBubble,
+       let _ = props.layout.time,
+       let timeViewTopConstraint
+    {
+      let timeTopOffset = props.layout.hasText ?
+        props.layout.textContentViewTop :
+        props.layout.topMostContentTopSpacing
+      if timeViewTopConstraint.constant != timeTopOffset {
+        timeViewTopConstraint.constant = timeTopOffset
+      }
+    }
@@
-    timeAndStateView.updateMessage(fullMessage, overlay: isTimeOverlay)
+    timeAndStateView.updateMessage(
+      fullMessage,
+      overlay: isTimeOverlay,
+      useNeutralStyle: isNonBubble
+    )
+    updateTimeAndStateVisibility(animated: false)
@@
-  private func setTimeAndStateVisibility(visible _: Bool) {
-//    NSAnimationContext.runAnimationGroup { context in
-//      context.duration = visible ? 0.05 : 0.05
-//      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
-//      context.allowsImplicitAnimation = true
-//      timeAndStateView.layer?.opacity = visible ? 1 : 0
-//    }
+  private func updateTimeAndStateVisibility(animated: Bool) {
+    guard isNonBubble else { return }
+    let shouldShow = isMouseInside || shouldAlwaysShowTimeAndState
+    if animated {
+      NSAnimationContext.runAnimationGroup { context in
+        context.duration = 0.08
+        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
+        context.allowsImplicitAnimation = true
+        timeAndStateView.animator().alphaValue = shouldShow ? 1.0 : 0.0
+      }
+    } else {
+      timeAndStateView.alphaValue = shouldShow ? 1.0 : 0.0
+    }
   }
@@
   private func updateHoverState(_ isHovered: Bool) {
     isMouseInside = isHovered
+    updateTimeAndStateVisibility(animated: true)
   }
*** End Patch
```

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/Message/MessageViewTypes.swift
@@
 struct MessageViewInputProps: Equatable, Codable, Hashable {
   var firstInGroup: Bool
   var isLastMessage: Bool?
   var isFirstMessage: Bool
   var isDM: Bool
   var isRtl: Bool
   var translated: Bool
+  var isNonBubble: Bool
 
   /// Used in cache key
   func toString() -> String {
-    "\(firstInGroup ? \"FG\" : \"\")\(isLastMessage == true ? \"LM\" : \"\")\(isFirstMessage == true ? \"FM\" : \"\")\(isRtl ? \"RTL\" : \"\")\(isDM ? \"DM\" : \"\")\(translated ? \"TR\" : \"\")"
+    "\(firstInGroup ? \"FG\" : \"\")\(isLastMessage == true ? \"LM\" : \"\")\(isFirstMessage == true ? \"FM\" : \"\")\(isRtl ? \"RTL\" : \"\")\(isDM ? \"DM\" : \"\")\(translated ? \"TR\" : \"\")\(isNonBubble ? \"NB\" : \"\")"
   }
 }
@@
 struct MessageViewProps: Equatable, Codable, Hashable {
   var firstInGroup: Bool
   var isLastMessage: Bool?
   var isFirstMessage: Bool
   var isRtl: Bool
   var isDM: Bool = false
+  var isNonBubble: Bool = false
   var index: Int?
   var translated: Bool
   var layout: MessageSizeCalculator.LayoutPlans
@@
       isFirstMessage == rhs.isFirstMessage &&
       isRtl == rhs.isRtl &&
       isDM == rhs.isDM &&
+      isNonBubble == rhs.isNonBubble &&
       translated == rhs.translated
   }
 }
*** End Patch
```

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/MessageList/MessageListAppKit.swift
@@
   private var messages: [FullMessage] { viewModel.messages }
   private var state: ChatState
+  private let useNonBubbleMessages: Bool
@@
     self.dependencies = dependencies
     self.peerId = peerId
     self.chat = chat
+    useNonBubbleMessages = AppSettings.shared.enableNonBubbleMessages
     viewModel = MessagesProgressiveViewModel(peer: peerId)
     state = ChatsManager
@@
             isFirstMessage: inputProps.isFirstMessage,
             isRtl: inputProps.isRtl,
             isDM: chat?.type == .privateChat,
+            isNonBubble: useNonBubbleMessages,
             index: messageIndexById[message.id],
             translated: inputProps.translated,
             layout: plan,
@@
       return MessageViewInputProps(
         firstInGroup: true,
         isLastMessage: true,
         isFirstMessage: true,
         isDM: chat?.type == .privateChat,
         isRtl: false,
-        translated: false
+        translated: false,
+        isNonBubble: useNonBubbleMessages
       )
@@
     return MessageViewInputProps(
       firstInGroup: isFirstInGroup(at: row),
       isLastMessage: isLastMessage(at: row),
       isFirstMessage: isFirstMessage(at: row),
       isDM: chat?.type == .privateChat,
       isRtl: false,
-      translated: message.isTranslated
+      translated: message.isTranslated,
+      isNonBubble: useNonBubbleMessages
     )
@@
         let props = MessageViewProps(
           firstInGroup: inputProps.firstInGroup,
           isLastMessage: inputProps.isLastMessage,
           isFirstMessage: inputProps.isFirstMessage,
           isRtl: inputProps.isRtl,
           isDM: chat?.type == .privateChat,
+          isNonBubble: useNonBubbleMessages,
           index: messageIndex,
           translated: inputProps.translated,
           layout: layoutPlan
*** End Patch
```

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift
@@
     let hasText = message.message.text != nil
+    let isNonBubble = props.isNonBubble
     let text = message.displayText ?? emptyFallback
@@
-    let hasBubbleColor = !emojiMessage && !isSticker
+    let hasBubbleColor = !isNonBubble && !emojiMessage && !isSticker
@@
         entities: message.message.entities,
         configuration: .init(
           font: font,
-          textColor: MessageViewAppKit.textColor(outgoing: isOutgoing),
-          linkColor: MessageViewAppKit.linkColor(outgoing: isOutgoing)
+          textColor: isNonBubble ? .labelColor : MessageViewAppKit.textColor(outgoing: isOutgoing),
+          linkColor: isNonBubble ? .linkColor : MessageViewAppKit.linkColor(outgoing: isOutgoing)
         )
       )
@@
+    let maxMediaSide: CGFloat = isNonBubble ? 240.0 : 320.0
@@
         stickerSize = calculatePhotoSize(
           width: min(120, width),
           height: min(120, height),
           parentAvailableWidth: parentAvailableWidth,
-          hasCaption: hasText
+          hasCaption: hasText,
+          maxSide: maxMediaSide
         )
       } else if message.file?.fileType == .photo || message.photoInfo != nil {
         photoSize = calculatePhotoSize(
           width: width,
           height: height,
           parentAvailableWidth: parentAvailableWidth,
-          hasCaption: hasText
+          hasCaption: hasText,
+          maxSide: maxMediaSide
         )
       } else if message.videoInfo != nil {
         videoSize = calculatePhotoSize(
           width: width,
           height: height,
           parentAvailableWidth: parentAvailableWidth,
-          hasCaption: hasText
+          hasCaption: hasText,
+          maxSide: maxMediaSide
         )
       }
@@
-    if hasMedia, let photoSize {
+    let bubbleHorizontalInset = isNonBubble ? 0.0 : (Theme.messageBubbleContentHorizontalInset * 2)
+    if hasMedia, let photoSize {
       // Photos strictly constrain text width
-      availableWidth = photoSize.width - (Theme.messageBubbleContentHorizontalInset * 2)
+      availableWidth = photoSize.width - bubbleHorizontalInset
     } else if hasMedia, let videoSize {
-      availableWidth = videoSize.width - (Theme.messageBubbleContentHorizontalInset * 2)
+      availableWidth = videoSize.width - bubbleHorizontalInset
     } else if hasDocument {
       // Documents don't restrict text width like photos - text can use full parent width
-      availableWidth = parentAvailableWidth - (Theme.messageBubbleContentHorizontalInset * 2)
+      availableWidth = parentAvailableWidth - bubbleHorizontalInset
     }
@@
-    if hasDocument, hasText, let currentDocumentWidth = documentWidth {
+    if hasDocument, hasText, let currentDocumentWidth = documentWidth {
       // Document can expand to fit text content, but has minimum and maximum bounds
-      let textWidthWithPadding = textWidth + (Theme.messageBubbleContentHorizontalInset * 2)
+      let textWidthWithPadding = textWidth + (isNonBubble ? 0 : (Theme.messageBubbleContentHorizontalInset * 2))
       documentWidth = max(currentDocumentWidth, min(parentAvailableWidth, textWidthWithPadding))
     }
@@
-    if isSingleLine, textWidth > availableWidth - MessageTimeAndState.timeWidth {
+    if isSingleLine, !isNonBubble, textWidth > availableWidth - MessageTimeAndState.timeWidth {
       isSingleLine = false
     }
@@
-    if props.firstInGroup, !isOutgoing, !props.isDM {
+    if props.firstInGroup, !props.isDM, (isNonBubble || !isOutgoing) {
       let nameHeight = Theme.messageNameLabelHeight
@@
-      let textSidePadding = hasBubbleColor ? Theme.messageBubbleContentHorizontalInset : 0
+      let textSidePadding = isNonBubble ? 0 : (hasBubbleColor ? Theme.messageBubbleContentHorizontalInset : 0)
+      let textOnlyInset: CGFloat = isNonBubble ? 2.0 : Theme.messageTextOnlyVerticalInsets
+      let textBottomInsetSingle: CGFloat = isNonBubble ? 2.0 : Theme.messageTextOnlyVerticalInsets
+      let textBottomInsetMulti: CGFloat = isNonBubble ? 2.0 : Theme.messageTextAndTimeSpacing
@@
-        textTopSpacing += Theme.messageTextOnlyVerticalInsets
+        textTopSpacing += textOnlyInset
@@
-        textBottomSpacing += Theme.messageTextOnlyVerticalInsets
+        textBottomSpacing += textBottomInsetSingle
       } else {
-        textBottomSpacing += Theme.messageTextAndTimeSpacing
+        textBottomSpacing += textBottomInsetMulti
       }
@@
     if hasReply {
+      let replyHorizontalInset = isNonBubble ? 0 : Theme.messageBubbleContentHorizontalInset
       replyPlan = LayoutPlan(size: .zero, spacing: .zero)
       replyPlan!.size.height = Theme.embeddedMessageHeight
       replyPlan!.size.width = 200
       replyPlan!.spacing = .init(
         top: 6.0,
-        left: Theme.messageBubbleContentHorizontalInset,
+        left: replyHorizontalInset,
         bottom: 3.0,
-        right: Theme.messageBubbleContentHorizontalInset
+        right: replyHorizontalInset
       )
     }
@@
     if hasDocument, let documentWidth {
+      let documentHorizontalInset = isNonBubble ? 0 : Theme.messageBubbleContentHorizontalInset
       documentPlan = LayoutPlan(size: .zero, spacing: .zero)
@@
         documentPlan!.spacing = NSEdgeInsets(
           top: 8,
-          left: Theme.messageBubbleContentHorizontalInset,
+          left: documentHorizontalInset,
           bottom: Theme.messageTextAndPhotoSpacing,
-          right: Theme.messageBubbleContentHorizontalInset
+          right: documentHorizontalInset
         )
       } else {
         documentPlan!.spacing = NSEdgeInsets(
           top: 8,
-          left: Theme.messageBubbleContentHorizontalInset,
+          left: documentHorizontalInset,
           bottom: 8,
-          right: Theme.messageBubbleContentHorizontalInset
+          right: documentHorizontalInset
         )
       }
     }
@@
     if hasAttachments, let attachmentsWidth {
+      let attachmentsHorizontalInset = isNonBubble ? 0 : Theme.messageBubbleContentHorizontalInset
       attachmentsPlan = LayoutPlan(size: .zero, spacing: .zero)
@@
       attachmentsPlan!.spacing = NSEdgeInsets(
         top: Theme.messageTextAndPhotoSpacing,
-        left: Theme.messageBubbleContentHorizontalInset,
+        left: attachmentsHorizontalInset,
         bottom: 4, // between time and attackment
-        right: Theme.messageBubbleContentHorizontalInset
+        right: attachmentsHorizontalInset
       )
@@
     if hasReactions {
+      let reactionsHorizontalInset: CGFloat = isNonBubble ? 0.0 : 8.0
       reactionsPlan = LayoutPlan(
         size: .zero,
         spacing: NSEdgeInsets(
           top: 8.0,
-          left: 8.0,
+          left: reactionsHorizontalInset,
           bottom: 0.0,
-          right: 8.0
+          right: reactionsHorizontalInset
         )
       )
@@
-    if isSingleLine {
+    if isNonBubble {
+      timePlan!.spacing = .zero
+    } else if isSingleLine {
       timePlan!.spacing = .init(top: 0, left: 0, bottom: 5.0, right: 9.0)
     } else {
@@
-    if isSingleLine, let textPlan, (photoPlan != nil || videoPlan != nil) {
+    if !isNonBubble, isSingleLine, let textPlan, (photoPlan != nil || videoPlan != nil) {
       let textWidth = textPlan.size.width + textPlan.spacing.horizontalTotal
@@
-      if isSingleLine, let timePlan {
+      if !isNonBubble, isSingleLine, let timePlan {
         bubbleWidth = max(bubbleWidth, textPlan.size.width + textPlan.spacing.horizontalTotal + timePlan.size.width)
       }
     }
@@
-    if let timePlan {
+    if let timePlan, !isNonBubble {
       if !isSingleLine, hasText {
         bubbleHeight += timePlan.size.height
         bubbleHeight += timePlan.spacing.verticalTotal // ??? probably too much
@@
-    wrapperPlan.spacing = .init(
-      top: wrapperTopSpacing + Theme.messageOuterVerticalPadding,
-      left: 0,
-      bottom: Theme.messageOuterVerticalPadding,
-      right: 0
-    )
+    let outerVerticalPadding = isNonBubble ? 1.0 : Theme.messageOuterVerticalPadding
+    let nonBubbleBottomPadding = isNonBubble ? 0.0 : outerVerticalPadding
+    wrapperPlan.spacing = .init(
+      top: wrapperTopSpacing + outerVerticalPadding,
+      left: 0,
+      bottom: nonBubbleBottomPadding,
+      right: 0
+    )
@@
     plan = LayoutPlans(
@@
       hasBubbleColor: hasBubbleColor
     )
 
+    if isNonBubble, props.firstInGroup, var avatarPlan = plan.avatar {
+      if plan.hasName {
+        avatarPlan.spacing.top = 0
+      } else if plan.hasText {
+        avatarPlan.spacing.top = plan.textContentViewTop
+      } else {
+        avatarPlan.spacing.top = plan.topMostContentTopSpacing
+      }
+      plan.avatar = avatarPlan
+    }
@@
   private func calculatePhotoSize(
     width: CGFloat,
     height: CGFloat,
     parentAvailableWidth: CGFloat,
-    hasCaption: Bool
+    hasCaption: Bool,
+    maxSide: CGFloat
   ) -> CGSize {
     let maxMediaSize = CGSize(
-      width: min(320, ceil(parentAvailableWidth)),
-      height: min(320, ceil(parentAvailableWidth))
+      width: min(maxSide, ceil(parentAvailableWidth)),
+      height: min(maxSide, ceil(parentAvailableWidth))
     )
*** End Patch
```

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/Settings/AppSettings.swift
@@
 final class AppSettings: ObservableObject {
@@
+  @Published var enableNonBubbleMessages: Bool {
+    didSet {
+      UserDefaults.standard.set(enableNonBubbleMessages, forKey: "enableNonBubbleMessages")
+    }
+  }
+
   private init() {
@@
     disableNotificationSound = UserDefaults.standard.bool(forKey: "disableNotificationSound")
     showDockBadgeUnreadDMs = UserDefaults.standard.object(forKey: "showDockBadgeUnreadDMs") as? Bool ?? true
     enableNewMacUI = UserDefaults.standard.bool(forKey: "enableNewMacUI")
+    enableNonBubbleMessages = UserDefaults.standard.bool(forKey: "enableNonBubbleMessages")
   }
 }
*** End Patch
```

```diff
*** Begin Patch
*** Update File: apple/InlineMac/Views/Settings/Views/ExperimentalSettingsDetailView.swift
@@
     Form {
       Section("Experimental") {
         Toggle("Enable new Mac UI", isOn: $appSettings.enableNewMacUI)
+        Toggle("Enable non-bubble messages", isOn: $appSettings.enableNonBubbleMessages)
         Text("Changes require an app restart to take effect.")
           .font(.caption)
           .foregroundStyle(.secondary)
*** End Patch
```
