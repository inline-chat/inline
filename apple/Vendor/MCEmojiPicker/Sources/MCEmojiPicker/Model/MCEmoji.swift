// The MIT License (MIT)
//
// Copyright © 2022 Ivan Izyumkin
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

/// The main model for interacting with emojis.
struct MCEmoji {
    
    // MARK: - Types
    
    /// Keys for storage in UserDefaults.
    private enum StorageKeys {
        case skinTone(_ emoji: MCEmoji)
        case usageTimestamps(_ emoji: MCEmoji)

        var key: String {
            switch self {
            case .skinTone(let emoji):
                return emoji.emojiKeys.emoji()
            case .usageTimestamps(let emoji):
                return StorageKeys.skinTone(emoji).key + "-usage-timestamps"
            }
        }
    }
    
    // MARK: - Public Properties
    
    /// A boolean indicating whether the skin for this emoji has been selected before.
    public var isSkinBeenSelectedBefore: Bool {
        skinTone != nil
    }
    /// The current skin tone for this emoji, if one has been selected.
    public var skinTone: MCEmojiSkinTone? {
        let skinToneRawValue = UserDefaults.standard.integer(forKey: StorageKeys.skinTone(self).key)
        return MCEmojiSkinTone(rawValue: skinToneRawValue)
    }
    /// All times when the emoji has been selected.
    public var usage: [TimeInterval] {
        (UserDefaults.standard.array(forKey: StorageKeys.usageTimestamps(self).key) as? [TimeInterval]) ?? []
    }
    /// The number of times this emoji has been selected.
    public var usageCount: Int {
        usage.count
    }
    /// The last time when this emoji has been selected.
    public var lastUsage: TimeInterval {
        usage.first ?? .zero
    }
    
    /// The string representation of the emoji.
    private(set) public var string: String = ""
    /// The keys used to represent the emoji.
    private(set) public var emojiKeys: [Int]
    /// A boolean indicating whether this emoji has different skin tones available.
    private(set) public var isSkinToneSupport: Bool
    /// The search key for the emoji.
    private(set) public var searchKey: String
    /// The emoji version.
    private(set) public var version: Double
    
    // MARK: - Initializers
    
    /// Initializes a new instance of the `MCEmoji` struct.
    
    /// - Parameters:
    ///   - emojiKeys: The keys used to represent the emoji.
    ///   - isSkinToneSupport: A boolean indicating whether this emoji has different skin tones available.
    ///   - searchKey: The search key for the emoji.
    ///   - version: The emoji version.
    public init(
        emojiKeys: [Int],
        isSkinToneSupport: Bool,
        searchKey: String,
        version: Double
    ) {
        self.emojiKeys = emojiKeys
        self.isSkinToneSupport = isSkinToneSupport
        self.searchKey = searchKey
        self.version = version
        
        string = getEmoji()
    }
    
    // MARK: - Public Methods

    /// Sets the skin tone of the emoji.
    
    /// - Parameters:
    ///   - skinToneRawValue: The raw value of the `MCEmojiSkinTone`.
    public mutating func set(skinToneRawValue: Int) {
        UserDefaults.standard.set(skinToneRawValue, forKey: StorageKeys.skinTone(self).key)
        string = getEmoji()
    }
    
    /// Increments the usage count for this emoji.
    public func incrementUsageCount() {
        let nowTimestamp = Date().timeIntervalSince1970
        UserDefaults.standard.set([nowTimestamp] + usage, forKey: StorageKeys.usageTimestamps(self).key)
    }
    
    // MARK: - Private Methods
    
    /// Returns the string representation of this smiley. Considering the skin tone, if it has been selected.
    private func getEmoji() -> String {
        guard isSkinToneSupport,
              let skinTone = skinTone,
              let skinToneKey = skinTone.skinKey else {
            return emojiKeys.emoji()
        }
        var bufferEmojiKeys = emojiKeys
        bufferEmojiKeys.insert(skinToneKey, at: 1)
        return bufferEmojiKeys.emoji()
    }
}

/// This enumeration allows you to determine which skin tones can be set for `MCEmoji`.
enum MCEmojiSkinTone: Int, CaseIterable {
    case none = 1
    case light = 2
    case mediumLight = 3
    case medium = 4
    case mediumDark = 5
    case dark = 6
    
    /// Hex value for the skin tone.
    var skinKey: Int? {
        switch self {
        case .none:
            return nil
        case .light:
            return 0x1F3FB
        case .mediumLight:
            return 0x1F3FC
        case .medium:
            return 0x1F3FD
        case .mediumDark:
            return 0x1F3FE
        case .dark:
            return 0x1F3FF
        }
    }
}
