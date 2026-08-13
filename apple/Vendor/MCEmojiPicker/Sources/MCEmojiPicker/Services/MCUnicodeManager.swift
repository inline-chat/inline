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
import UIKit.UIDevice

/// Protocol for the `MCUnicodeManager`.
protocol MCUnicodeManagerProtocol {
    /// Returns categories with filtered emoji arrays that are available in the current version of iOS.
    func getEmojisForCurrentIOSVersion() -> [MCEmojiCategory]
}

fileprivate extension MCEmojiCategoryType {
    var emojiCategoryTitle: String {
        NSLocalizedString(
            self.localizeKey,
            tableName: "MCEmojiPickerLocalizable",
            bundle: .module,
            comment: ""
        )
    }
}

/// The class is responsible for getting a relevant set of emojis for iOS version.
final class MCUnicodeManager: MCUnicodeManagerProtocol {
    
    /// The maximum number of frequently used emojis to include in the `frequentlyUsed` category.
    public let maxFrequentlyUsedEmojisCount: Int
    
    // MARK: - Initializers
    
    public init(maxFrequentlyUsedEmojis: Int = 30) {
        self.maxFrequentlyUsedEmojisCount = maxFrequentlyUsedEmojis
    }
    
    // MARK: - Public Methods
    
    /// Returns all emojis available for the current device's iOS version.
    func getEmojisForCurrentIOSVersion() -> [MCEmojiCategory] {
        let frequentlyUsedEmojis: MCEmojiCategory = .init(
            type: .frequentlyUsed,
            categoryName: MCEmojiCategoryType.frequentlyUsed.emojiCategoryTitle,
            emojis: getFrequentlyUsedEmojis()
        )
        return [frequentlyUsedEmojis] + defaultEmojis
    }
    
    // MARK: - Private Methods

    /// Returns the top n (`maxFrequentlyUsedEmojis`) emojis by usage, for emojis with a `usageCount` > 0.
    private func getFrequentlyUsedEmojis() -> [MCEmoji] {
        Array(
            defaultEmojis
                .flatMap({ $0.emojis })
                .filter({ $0.usageCount > 0 })
                .sorted(by: { lhs, rhs in
                    let (aUsage, bUsage) = (lhs.usage, rhs.usage)
                    guard aUsage.count != bUsage.count else {
                        // Break ties with most recent usage
                        return lhs.lastUsage > rhs.lastUsage
                    }
                    return aUsage.count > bUsage.count
                })
                .prefix(maxFrequentlyUsedEmojisCount)
        )
    }

    // MARK: - Private Properties
    
    /// The maximum available emoji version for the current iOS version.
    private static let maxCurrentAvailableEmojiVersion: Double = {
        let currentIOSVersion = (UIDevice.current.systemVersion as NSString).floatValue
        switch currentIOSVersion {
        case 12.1...13.1:
            return 11.0
        case 13.2...14.1:
            return 12.0
        case 14.2...14.4:
            return 13.0
        case 14.5...15.3:
            return 13.1
        case 15.4...16.3:
            return 14.0
        case 16.4...:
            return 15.0
        default:
            return 5.0
        }
    }()
    
    private var defaultEmojis: [MCEmojiCategory] {
        [
            peopleEmojis,
            natureEmojis,
            foodAndDrinkEmojis,
            activityEmojis,
            travelAndPlacesEmojis,
            objectEmojis,
            symbolEmojis,
            flagEmojis
        ]
    }
    
    private let peopleEmojis: MCEmojiCategory = .init(
        type: .people,
        categoryName: MCEmojiCategoryType.people.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F600],
                isSkinToneSupport: false,
                searchKey: "grinningFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F603],
                isSkinToneSupport: false,
                searchKey: "grinningFaceWithBigEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F604],
                isSkinToneSupport: false,
                searchKey: "grinningFaceWithSmilingEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F601],
                isSkinToneSupport: false,
                searchKey: "beamingFaceWithSmilingEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F606],
                isSkinToneSupport: false,
                searchKey: "grinningSquintingFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F605],
                isSkinToneSupport: false,
                searchKey: "grinningFaceWithSweat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F923],
                isSkinToneSupport: false,
                searchKey: "rollingOnTheFloorLaughing",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F602],
                isSkinToneSupport: false,
                searchKey: "faceWithTearsOfJoy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F642],
                isSkinToneSupport: false,
                searchKey: "slightlySmilingFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F643],
                isSkinToneSupport: false,
                searchKey: "upsideDownFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE0],
                isSkinToneSupport: false,
                searchKey: "meltingFace",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F609],
                isSkinToneSupport: false,
                searchKey: "winkingFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F60A],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithSmilingEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F607],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithHalo",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F970],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithHearts",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F60D],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithHeartEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F929],
                isSkinToneSupport: false,
                searchKey: "starStruck",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F618],
                isSkinToneSupport: false,
                searchKey: "faceBlowingAKiss",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F617],
                isSkinToneSupport: false,
                searchKey: "kissingFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x263A, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "smilingFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F61A],
                isSkinToneSupport: false,
                searchKey: "kissingFaceWithClosedEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F619],
                isSkinToneSupport: false,
                searchKey: "kissingFaceWithSmilingEyes",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F972],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithTear",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F60B],
                isSkinToneSupport: false,
                searchKey: "faceSavoringFood",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F61B],
                isSkinToneSupport: false,
                searchKey: "faceWithTongue",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F61C],
                isSkinToneSupport: false,
                searchKey: "winkingFaceWithTongue",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F92A],
                isSkinToneSupport: false,
                searchKey: "zanyFace",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F61D],
                isSkinToneSupport: false,
                searchKey: "squintingFaceWithTongue",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F911],
                isSkinToneSupport: false,
                searchKey: "moneyMouthFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F917],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithOpenHands",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F92D],
                isSkinToneSupport: false,
                searchKey: "faceWithHandOverMouth",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE2],
                isSkinToneSupport: false,
                searchKey: "faceWithOpenEyesAndHandOverMouth",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE3],
                isSkinToneSupport: false,
                searchKey: "faceWithPeekingEye",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F92B],
                isSkinToneSupport: false,
                searchKey: "shushingFace",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F914],
                isSkinToneSupport: false,
                searchKey: "thinkingFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE1],
                isSkinToneSupport: false,
                searchKey: "salutingFace",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F910],
                isSkinToneSupport: false,
                searchKey: "zipperMouthFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F928],
                isSkinToneSupport: false,
                searchKey: "faceWithRaisedEyebrow",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F610],
                isSkinToneSupport: false,
                searchKey: "neutralFace",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F611],
                isSkinToneSupport: false,
                searchKey: "expressionlessFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F636],
                isSkinToneSupport: false,
                searchKey: "faceWithoutMouth",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE5],
                isSkinToneSupport: false,
                searchKey: "dottedLineFace",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F636, 0x200D, 0x1F32B, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "faceInClouds",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x1F60F],
                isSkinToneSupport: false,
                searchKey: "smirkingFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F612],
                isSkinToneSupport: false,
                searchKey: "unamusedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F644],
                isSkinToneSupport: false,
                searchKey: "faceWithRollingEyes",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F62C],
                isSkinToneSupport: false,
                searchKey: "grimacingFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F62E, 0x200D, 0x1F4A8],
                isSkinToneSupport: false,
                searchKey: "faceExhaling",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x1F925],
                isSkinToneSupport: false,
                searchKey: "lyingFace",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE8],
                isSkinToneSupport: false,
                searchKey: "shakingFace",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F60C],
                isSkinToneSupport: false,
                searchKey: "relievedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F614],
                isSkinToneSupport: false,
                searchKey: "pensiveFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F62A],
                isSkinToneSupport: false,
                searchKey: "sleepyFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F924],
                isSkinToneSupport: false,
                searchKey: "droolingFace",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F634],
                isSkinToneSupport: false,
                searchKey: "sleepingFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F637],
                isSkinToneSupport: false,
                searchKey: "faceWithMedicalMask",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F912],
                isSkinToneSupport: false,
                searchKey: "faceWithThermometer",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F915],
                isSkinToneSupport: false,
                searchKey: "faceWithHeadBandage",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F922],
                isSkinToneSupport: false,
                searchKey: "nauseatedFace",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F92E],
                isSkinToneSupport: false,
                searchKey: "faceVomiting",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F927],
                isSkinToneSupport: false,
                searchKey: "sneezingFace",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F975],
                isSkinToneSupport: false,
                searchKey: "hotFace",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F976],
                isSkinToneSupport: false,
                searchKey: "coldFace",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F974],
                isSkinToneSupport: false,
                searchKey: "woozyFace",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F635],
                isSkinToneSupport: false,
                searchKey: "faceWithCrossedOutEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F635, 0x200D, 0x1F4AB],
                isSkinToneSupport: false,
                searchKey: "faceWithSpiralEyes",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x1F92F],
                isSkinToneSupport: false,
                searchKey: "explodingHead",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F920],
                isSkinToneSupport: false,
                searchKey: "cowboyHatFace",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F973],
                isSkinToneSupport: false,
                searchKey: "partyingFace",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F978],
                isSkinToneSupport: false,
                searchKey: "disguisedFace",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F60E],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithSunglasses",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F913],
                isSkinToneSupport: false,
                searchKey: "nerdFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D0],
                isSkinToneSupport: false,
                searchKey: "faceWithMonocle",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F615],
                isSkinToneSupport: false,
                searchKey: "confusedFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE4],
                isSkinToneSupport: false,
                searchKey: "faceWithDiagonalMouth",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F61F],
                isSkinToneSupport: false,
                searchKey: "worriedFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F641],
                isSkinToneSupport: false,
                searchKey: "slightlyFrowningFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x2639, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "frowningFace",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F62E],
                isSkinToneSupport: false,
                searchKey: "faceWithOpenMouth",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F62F],
                isSkinToneSupport: false,
                searchKey: "hushedFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F632],
                isSkinToneSupport: false,
                searchKey: "astonishedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F633],
                isSkinToneSupport: false,
                searchKey: "flushedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F97A],
                isSkinToneSupport: false,
                searchKey: "pleadingFace",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F979],
                isSkinToneSupport: false,
                searchKey: "faceHoldingBackTears",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F626],
                isSkinToneSupport: false,
                searchKey: "frowningFaceWithOpenMouth",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F627],
                isSkinToneSupport: false,
                searchKey: "anguishedFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F628],
                isSkinToneSupport: false,
                searchKey: "fearfulFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F630],
                isSkinToneSupport: false,
                searchKey: "anxiousFaceWithSweat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F625],
                isSkinToneSupport: false,
                searchKey: "sadButRelievedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F622],
                isSkinToneSupport: false,
                searchKey: "cryingFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F62D],
                isSkinToneSupport: false,
                searchKey: "loudlyCryingFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F631],
                isSkinToneSupport: false,
                searchKey: "faceScreamingInFear",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F616],
                isSkinToneSupport: false,
                searchKey: "confoundedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F623],
                isSkinToneSupport: false,
                searchKey: "perseveringFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F61E],
                isSkinToneSupport: false,
                searchKey: "disappointedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F613],
                isSkinToneSupport: false,
                searchKey: "downcastFaceWithSweat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F629],
                isSkinToneSupport: false,
                searchKey: "wearyFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F62B],
                isSkinToneSupport: false,
                searchKey: "tiredFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F971],
                isSkinToneSupport: false,
                searchKey: "yawningFace",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F624],
                isSkinToneSupport: false,
                searchKey: "faceWithSteamFromNose",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F621],
                isSkinToneSupport: false,
                searchKey: "enragedFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F620],
                isSkinToneSupport: false,
                searchKey: "angryFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F92C],
                isSkinToneSupport: false,
                searchKey: "faceWithSymbolsOnMouth",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F608],
                isSkinToneSupport: false,
                searchKey: "smilingFaceWithHorns",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F47F],
                isSkinToneSupport: false,
                searchKey: "angryFaceWithHorns",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F480],
                isSkinToneSupport: false,
                searchKey: "skull",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2620, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "skullAndCrossbones",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4A9],
                isSkinToneSupport: false,
                searchKey: "pileOfPoo",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F921],
                isSkinToneSupport: false,
                searchKey: "clownFace",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F479],
                isSkinToneSupport: false,
                searchKey: "ogre",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F47A],
                isSkinToneSupport: false,
                searchKey: "goblin",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F47B],
                isSkinToneSupport: false,
                searchKey: "ghost",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F47D],
                isSkinToneSupport: false,
                searchKey: "alien",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F47E],
                isSkinToneSupport: false,
                searchKey: "alienMonster",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F916],
                isSkinToneSupport: false,
                searchKey: "robot",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F63A],
                isSkinToneSupport: false,
                searchKey: "grinningCat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F638],
                isSkinToneSupport: false,
                searchKey: "grinningCatWithSmilingEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F639],
                isSkinToneSupport: false,
                searchKey: "catWithTearsOfJoy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F63B],
                isSkinToneSupport: false,
                searchKey: "smilingCatWithHeartEyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F63C],
                isSkinToneSupport: false,
                searchKey: "catWithWrySmile",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F63D],
                isSkinToneSupport: false,
                searchKey: "kissingCat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F640],
                isSkinToneSupport: false,
                searchKey: "wearyCat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F63F],
                isSkinToneSupport: false,
                searchKey: "cryingCat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F63E],
                isSkinToneSupport: false,
                searchKey: "poutingCat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F648],
                isSkinToneSupport: false,
                searchKey: "seeNoEvilMonkey",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F649],
                isSkinToneSupport: false,
                searchKey: "hearNoEvilMonkey",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F64A],
                isSkinToneSupport: false,
                searchKey: "speakNoEvilMonkey",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F48C],
                isSkinToneSupport: false,
                searchKey: "loveLetter",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F498],
                isSkinToneSupport: false,
                searchKey: "heartWithArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F49D],
                isSkinToneSupport: false,
                searchKey: "heartWithRibbon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F496],
                isSkinToneSupport: false,
                searchKey: "sparklingHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F497],
                isSkinToneSupport: false,
                searchKey: "growingHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F493],
                isSkinToneSupport: false,
                searchKey: "beatingHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F49E],
                isSkinToneSupport: false,
                searchKey: "revolvingHearts",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F495],
                isSkinToneSupport: false,
                searchKey: "twoHearts",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F49F],
                isSkinToneSupport: false,
                searchKey: "heartDecoration",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2763, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "heartExclamation",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F494],
                isSkinToneSupport: false,
                searchKey: "brokenHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2764, 0xFE0F, 0x200D, 0x1F525],
                isSkinToneSupport: false,
                searchKey: "heartOnFire",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x2764, 0xFE0F, 0x200D, 0x1FA79],
                isSkinToneSupport: false,
                searchKey: "mendingHeart",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x2764, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "redHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA77],
                isSkinToneSupport: false,
                searchKey: "pinkHeart",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9E1],
                isSkinToneSupport: false,
                searchKey: "orangeHeart",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F49B],
                isSkinToneSupport: false,
                searchKey: "yellowHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F49A],
                isSkinToneSupport: false,
                searchKey: "greenHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F499],
                isSkinToneSupport: false,
                searchKey: "blueHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA75],
                isSkinToneSupport: false,
                searchKey: "lightBlueHeart",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F49C],
                isSkinToneSupport: false,
                searchKey: "purpleHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F90E],
                isSkinToneSupport: false,
                searchKey: "brownHeart",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5A4],
                isSkinToneSupport: false,
                searchKey: "blackHeart",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA76],
                isSkinToneSupport: false,
                searchKey: "greyHeart",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F90D],
                isSkinToneSupport: false,
                searchKey: "whiteHeart",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F48B],
                isSkinToneSupport: false,
                searchKey: "kissMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4AF],
                isSkinToneSupport: false,
                searchKey: "hundredPoints",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4A2],
                isSkinToneSupport: false,
                searchKey: "angerSymbol",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4A5],
                isSkinToneSupport: false,
                searchKey: "collision",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4AB],
                isSkinToneSupport: false,
                searchKey: "dizzy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4A6],
                isSkinToneSupport: false,
                searchKey: "sweatDroplets",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4A8],
                isSkinToneSupport: false,
                searchKey: "dashingAway",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F573, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "hole",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4AC],
                isSkinToneSupport: false,
                searchKey: "speechBalloon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F441, 0xFE0F, 0x200D, 0x1F5E8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "eyeInSpeechBubble",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5E8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "leftSpeechBubble",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5EF, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rightAngerBubble",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4AD],
                isSkinToneSupport: false,
                searchKey: "thoughtBalloon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4A4],
                isSkinToneSupport: false,
                searchKey: "zZZ",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F44B],
                isSkinToneSupport: true,
                searchKey: "wavingHand",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F91A],
                isSkinToneSupport: true,
                searchKey: "raisedBackOfHand",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F590, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "handWithFingersSplayed",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x270B],
                isSkinToneSupport: true,
                searchKey: "raisedHand",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F596],
                isSkinToneSupport: true,
                searchKey: "vulcanSalute",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF1],
                isSkinToneSupport: true,
                searchKey: "rightwardsHand",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF2],
                isSkinToneSupport: true,
                searchKey: "leftwardsHand",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF3],
                isSkinToneSupport: true,
                searchKey: "palmDownHand",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF4],
                isSkinToneSupport: true,
                searchKey: "palmUpHand",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF7],
                isSkinToneSupport: true,
                searchKey: "leftwardsPushingHand",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF8],
                isSkinToneSupport: true,
                searchKey: "rightwardsPushingHand",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F44C],
                isSkinToneSupport: true,
                searchKey: "oKHand",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F90C],
                isSkinToneSupport: true,
                searchKey: "pinchedFingers",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F90F],
                isSkinToneSupport: true,
                searchKey: "pinchingHand",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x270C, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "victoryHand",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F91E],
                isSkinToneSupport: true,
                searchKey: "crossedFingers",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAF0],
                isSkinToneSupport: true,
                searchKey: "handWithIndexFingerAndThumbCrossed",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F91F],
                isSkinToneSupport: true,
                searchKey: "loveYouGesture",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F918],
                isSkinToneSupport: true,
                searchKey: "signOfTheHorns",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F919],
                isSkinToneSupport: true,
                searchKey: "callMeHand",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F448],
                isSkinToneSupport: true,
                searchKey: "backhandIndexPointingLeft",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F449],
                isSkinToneSupport: true,
                searchKey: "backhandIndexPointingRight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F446],
                isSkinToneSupport: true,
                searchKey: "backhandIndexPointingUp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F595],
                isSkinToneSupport: true,
                searchKey: "middleFinger",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F447],
                isSkinToneSupport: true,
                searchKey: "backhandIndexPointingDown",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x261D, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "indexPointingUp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAF5],
                isSkinToneSupport: true,
                searchKey: "indexPointingAtTheViewer",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F44D],
                isSkinToneSupport: true,
                searchKey: "thumbsUp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F44E],
                isSkinToneSupport: true,
                searchKey: "thumbsDown",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x270A],
                isSkinToneSupport: true,
                searchKey: "raisedFist",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F44A],
                isSkinToneSupport: true,
                searchKey: "oncomingFist",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F91B],
                isSkinToneSupport: true,
                searchKey: "leftFacingFist",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F91C],
                isSkinToneSupport: true,
                searchKey: "rightFacingFist",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F44F],
                isSkinToneSupport: true,
                searchKey: "clappingHands",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F64C],
                isSkinToneSupport: true,
                searchKey: "raisingHands",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAF6],
                isSkinToneSupport: true,
                searchKey: "heartHands",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F450],
                isSkinToneSupport: true,
                searchKey: "openHands",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F932],
                isSkinToneSupport: true,
                searchKey: "palmsUpTogether",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F91D],
                isSkinToneSupport: false,
                searchKey: "handshake",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F64F],
                isSkinToneSupport: true,
                searchKey: "foldedHands",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x270D, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "writingHand",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F485],
                isSkinToneSupport: true,
                searchKey: "nailPolish",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F933],
                isSkinToneSupport: true,
                searchKey: "selfie",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4AA],
                isSkinToneSupport: true,
                searchKey: "flexedBiceps",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9BE],
                isSkinToneSupport: false,
                searchKey: "mechanicalArm",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9BF],
                isSkinToneSupport: false,
                searchKey: "mechanicalLeg",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B5],
                isSkinToneSupport: true,
                searchKey: "leg",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B6],
                isSkinToneSupport: true,
                searchKey: "foot",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F442],
                isSkinToneSupport: true,
                searchKey: "ear",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9BB],
                isSkinToneSupport: true,
                searchKey: "earWithHearingAid",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F443],
                isSkinToneSupport: true,
                searchKey: "nose",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9E0],
                isSkinToneSupport: false,
                searchKey: "brain",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAC0],
                isSkinToneSupport: false,
                searchKey: "anatomicalHeart",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAC1],
                isSkinToneSupport: false,
                searchKey: "lungs",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B7],
                isSkinToneSupport: false,
                searchKey: "tooth",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B4],
                isSkinToneSupport: false,
                searchKey: "bone",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F440],
                isSkinToneSupport: false,
                searchKey: "eyes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F441, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "eye",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F445],
                isSkinToneSupport: false,
                searchKey: "tongue",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F444],
                isSkinToneSupport: false,
                searchKey: "mouth",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAE6],
                isSkinToneSupport: false,
                searchKey: "bitingLip",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F476],
                isSkinToneSupport: true,
                searchKey: "baby",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9D2],
                isSkinToneSupport: true,
                searchKey: "child",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F466],
                isSkinToneSupport: true,
                searchKey: "boy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F467],
                isSkinToneSupport: true,
                searchKey: "girl",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1],
                isSkinToneSupport: true,
                searchKey: "person",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F471],
                isSkinToneSupport: true,
                searchKey: "personBlondHair",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F468],
                isSkinToneSupport: true,
                searchKey: "man",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9D4],
                isSkinToneSupport: true,
                searchKey: "personBeard",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D4, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manBeard",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x1F9D4, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanBeard",
                version: 13.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9B0],
                isSkinToneSupport: true,
                searchKey: "manRedHair",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9B1],
                isSkinToneSupport: true,
                searchKey: "manCurlyHair",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9B3],
                isSkinToneSupport: true,
                searchKey: "manWhiteHair",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9B2],
                isSkinToneSupport: true,
                searchKey: "manBald",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469],
                isSkinToneSupport: true,
                searchKey: "woman",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9B0],
                isSkinToneSupport: true,
                searchKey: "womanRedHair",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9B0],
                isSkinToneSupport: true,
                searchKey: "personRedHair",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9B1],
                isSkinToneSupport: true,
                searchKey: "womanCurlyHair",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9B1],
                isSkinToneSupport: true,
                searchKey: "personCurlyHair",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9B3],
                isSkinToneSupport: true,
                searchKey: "womanWhiteHair",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9B3],
                isSkinToneSupport: true,
                searchKey: "personWhiteHair",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9B2],
                isSkinToneSupport: true,
                searchKey: "womanBald",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9B2],
                isSkinToneSupport: true,
                searchKey: "personBald",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F471, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanBlondHair",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F471, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manBlondHair",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D3],
                isSkinToneSupport: true,
                searchKey: "olderPerson",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F474],
                isSkinToneSupport: true,
                searchKey: "oldMan",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F475],
                isSkinToneSupport: true,
                searchKey: "oldWoman",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F64D],
                isSkinToneSupport: true,
                searchKey: "personFrowning",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F64D, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manFrowning",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F64D, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanFrowning",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F64E],
                isSkinToneSupport: true,
                searchKey: "personPouting",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F64E, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manPouting",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F64E, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanPouting",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F645],
                isSkinToneSupport: true,
                searchKey: "personGesturingNO",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F645, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manGesturingNO",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F645, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanGesturingNO",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F646],
                isSkinToneSupport: true,
                searchKey: "personGesturingOK",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F646, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manGesturingOK",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F646, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanGesturingOK",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F481],
                isSkinToneSupport: true,
                searchKey: "personTippingHand",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F481, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manTippingHand",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F481, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanTippingHand",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F64B],
                isSkinToneSupport: true,
                searchKey: "personRaisingHand",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F64B, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manRaisingHand",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F64B, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanRaisingHand",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CF],
                isSkinToneSupport: true,
                searchKey: "deafPerson",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CF, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "deafMan",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CF, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "deafWoman",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F647],
                isSkinToneSupport: true,
                searchKey: "personBowing",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F647, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manBowing",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F647, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanBowing",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F926],
                isSkinToneSupport: true,
                searchKey: "personFacepalming",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F926, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manFacepalming",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F926, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanFacepalming",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F937],
                isSkinToneSupport: true,
                searchKey: "personShrugging",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F937, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manShrugging",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F937, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanShrugging",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x2695, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "healthWorker",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x2695, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manHealthWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2695, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanHealthWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F393],
                isSkinToneSupport: true,
                searchKey: "student",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F393],
                isSkinToneSupport: true,
                searchKey: "manStudent",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F393],
                isSkinToneSupport: true,
                searchKey: "womanStudent",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F3EB],
                isSkinToneSupport: true,
                searchKey: "teacher",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F3EB],
                isSkinToneSupport: true,
                searchKey: "manTeacher",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F3EB],
                isSkinToneSupport: true,
                searchKey: "womanTeacher",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x2696, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "judge",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x2696, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manJudge",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2696, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanJudge",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F33E],
                isSkinToneSupport: true,
                searchKey: "farmer",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F33E],
                isSkinToneSupport: true,
                searchKey: "manFarmer",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F33E],
                isSkinToneSupport: true,
                searchKey: "womanFarmer",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F373],
                isSkinToneSupport: true,
                searchKey: "cook",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F373],
                isSkinToneSupport: true,
                searchKey: "manCook",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F373],
                isSkinToneSupport: true,
                searchKey: "womanCook",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F527],
                isSkinToneSupport: true,
                searchKey: "mechanic",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F527],
                isSkinToneSupport: true,
                searchKey: "manMechanic",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F527],
                isSkinToneSupport: true,
                searchKey: "womanMechanic",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F3ED],
                isSkinToneSupport: true,
                searchKey: "factoryWorker",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F3ED],
                isSkinToneSupport: true,
                searchKey: "manFactoryWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F3ED],
                isSkinToneSupport: true,
                searchKey: "womanFactoryWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F4BC],
                isSkinToneSupport: true,
                searchKey: "officeWorker",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F4BC],
                isSkinToneSupport: true,
                searchKey: "manOfficeWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F4BC],
                isSkinToneSupport: true,
                searchKey: "womanOfficeWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F52C],
                isSkinToneSupport: true,
                searchKey: "scientist",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F52C],
                isSkinToneSupport: true,
                searchKey: "manScientist",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F52C],
                isSkinToneSupport: true,
                searchKey: "womanScientist",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F4BB],
                isSkinToneSupport: true,
                searchKey: "technologist",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F4BB],
                isSkinToneSupport: true,
                searchKey: "manTechnologist",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F4BB],
                isSkinToneSupport: true,
                searchKey: "womanTechnologist",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F3A4],
                isSkinToneSupport: true,
                searchKey: "singer",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F3A4],
                isSkinToneSupport: true,
                searchKey: "manSinger",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F3A4],
                isSkinToneSupport: true,
                searchKey: "womanSinger",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F3A8],
                isSkinToneSupport: true,
                searchKey: "artist",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F3A8],
                isSkinToneSupport: true,
                searchKey: "manArtist",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F3A8],
                isSkinToneSupport: true,
                searchKey: "womanArtist",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x2708, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "pilot",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x2708, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manPilot",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2708, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanPilot",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F680],
                isSkinToneSupport: true,
                searchKey: "astronaut",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F680],
                isSkinToneSupport: true,
                searchKey: "manAstronaut",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F680],
                isSkinToneSupport: true,
                searchKey: "womanAstronaut",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F692],
                isSkinToneSupport: true,
                searchKey: "firefighter",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F692],
                isSkinToneSupport: true,
                searchKey: "manFirefighter",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F692],
                isSkinToneSupport: true,
                searchKey: "womanFirefighter",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F46E],
                isSkinToneSupport: true,
                searchKey: "policeOfficer",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F46E, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manPoliceOfficer",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F46E, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanPoliceOfficer",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F575, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "detective",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F575, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manDetective",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F575, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanDetective",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F482],
                isSkinToneSupport: true,
                searchKey: "guard",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F482, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manGuard",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F482, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanGuard",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F977],
                isSkinToneSupport: true,
                searchKey: "ninja",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F477],
                isSkinToneSupport: true,
                searchKey: "constructionWorker",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F477, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manConstructionWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F477, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanConstructionWorker",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAC5],
                isSkinToneSupport: true,
                searchKey: "personWithCrown",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F934],
                isSkinToneSupport: true,
                searchKey: "prince",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F478],
                isSkinToneSupport: true,
                searchKey: "princess",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F473],
                isSkinToneSupport: true,
                searchKey: "personWearingTurban",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F473, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manWearingTurban",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F473, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanWearingTurban",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F472],
                isSkinToneSupport: true,
                searchKey: "personWithSkullcap",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9D5],
                isSkinToneSupport: true,
                searchKey: "womanWithHeadscarf",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F935],
                isSkinToneSupport: true,
                searchKey: "personInTuxedo",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F935, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manInTuxedo",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F935, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanInTuxedo",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F470],
                isSkinToneSupport: true,
                searchKey: "personWithVeil",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F470, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manWithVeil",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F470, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanWithVeil",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F930],
                isSkinToneSupport: true,
                searchKey: "pregnantWoman",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAC3],
                isSkinToneSupport: true,
                searchKey: "pregnantMan",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAC4],
                isSkinToneSupport: true,
                searchKey: "pregnantPerson",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F931],
                isSkinToneSupport: true,
                searchKey: "breastFeeding",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F37C],
                isSkinToneSupport: true,
                searchKey: "womanFeedingBaby",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F37C],
                isSkinToneSupport: true,
                searchKey: "manFeedingBaby",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F37C],
                isSkinToneSupport: true,
                searchKey: "personFeedingBaby",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F47C],
                isSkinToneSupport: true,
                searchKey: "babyAngel",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F385],
                isSkinToneSupport: true,
                searchKey: "santaClaus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F936],
                isSkinToneSupport: true,
                searchKey: "mrsClaus",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F384],
                isSkinToneSupport: true,
                searchKey: "mxClaus",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B8],
                isSkinToneSupport: true,
                searchKey: "superhero",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B8, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manSuperhero",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B8, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanSuperhero",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B9],
                isSkinToneSupport: true,
                searchKey: "supervillain",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B9, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manSupervillain",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9B9, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanSupervillain",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D9],
                isSkinToneSupport: true,
                searchKey: "mage",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D9, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manMage",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D9, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanMage",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DA],
                isSkinToneSupport: true,
                searchKey: "fairy",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DA, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manFairy",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DA, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanFairy",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DB],
                isSkinToneSupport: true,
                searchKey: "vampire",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DB, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manVampire",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DB, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanVampire",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DC],
                isSkinToneSupport: true,
                searchKey: "merperson",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DC, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "merman",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DC, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "mermaid",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DD],
                isSkinToneSupport: true,
                searchKey: "elf",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DD, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manElf",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DD, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanElf",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DE],
                isSkinToneSupport: false,
                searchKey: "genie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DE, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "manGenie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DE, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "womanGenie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DF],
                isSkinToneSupport: false,
                searchKey: "zombie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DF, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "manZombie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9DF, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "womanZombie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CC],
                isSkinToneSupport: false,
                searchKey: "troll",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F486],
                isSkinToneSupport: true,
                searchKey: "personGettingMassage",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F486, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manGettingMassage",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F486, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanGettingMassage",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F487],
                isSkinToneSupport: true,
                searchKey: "personGettingHaircut",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F487, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manGettingHaircut",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F487, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanGettingHaircut",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B6],
                isSkinToneSupport: true,
                searchKey: "personWalking",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6B6, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manWalking",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B6, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanWalking",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CD],
                isSkinToneSupport: true,
                searchKey: "personStanding",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CD, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manStanding",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CD, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanStanding",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CE],
                isSkinToneSupport: true,
                searchKey: "personKneeling",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CE, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manKneeling",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CE, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanKneeling",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9AF],
                isSkinToneSupport: true,
                searchKey: "personWithWhiteCane",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9AF],
                isSkinToneSupport: true,
                searchKey: "manWithWhiteCane",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9AF],
                isSkinToneSupport: true,
                searchKey: "womanWithWhiteCane",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9BC],
                isSkinToneSupport: true,
                searchKey: "personInMotorizedWheelchair",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9BC],
                isSkinToneSupport: true,
                searchKey: "manInMotorizedWheelchair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9BC],
                isSkinToneSupport: true,
                searchKey: "womanInMotorizedWheelchair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F9BD],
                isSkinToneSupport: true,
                searchKey: "personInManualWheelchair",
                version: 12.1
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F9BD],
                isSkinToneSupport: true,
                searchKey: "manInManualWheelchair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F9BD],
                isSkinToneSupport: true,
                searchKey: "womanInManualWheelchair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C3],
                isSkinToneSupport: true,
                searchKey: "personRunning",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3C3, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manRunning",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C3, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanRunning",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F483],
                isSkinToneSupport: true,
                searchKey: "womanDancing",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F57A],
                isSkinToneSupport: true,
                searchKey: "manDancing",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F574, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "personInSuitLevitating",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F46F],
                isSkinToneSupport: false,
                searchKey: "peopleWithBunnyEars",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F46F, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "menWithBunnyEars",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F46F, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "womenWithBunnyEars",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D6],
                isSkinToneSupport: true,
                searchKey: "personInSteamyRoom",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D6, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manInSteamyRoom",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D6, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanInSteamyRoom",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D7],
                isSkinToneSupport: true,
                searchKey: "personClimbing",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D7, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manClimbing",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D7, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanClimbing",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93A],
                isSkinToneSupport: false,
                searchKey: "personFencing",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C7],
                isSkinToneSupport: true,
                searchKey: "horseRacing",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x26F7, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "skier",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3C2],
                isSkinToneSupport: false,
                searchKey: "snowboarder",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3CC, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "personGolfing",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3CC, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manGolfing",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3CC, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanGolfing",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C4],
                isSkinToneSupport: true,
                searchKey: "personSurfing",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3C4, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manSurfing",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C4, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanSurfing",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A3],
                isSkinToneSupport: true,
                searchKey: "personRowingBoat",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A3, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manRowingBoat",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A3, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanRowingBoat",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3CA],
                isSkinToneSupport: true,
                searchKey: "personSwimming",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3CA, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manSwimming",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3CA, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanSwimming",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x26F9, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "personBouncingBall",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x26F9, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manBouncingBall",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x26F9, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanBouncingBall",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3CB, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "personLiftingWeights",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3CB, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manLiftingWeights",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3CB, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanLiftingWeights",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B4],
                isSkinToneSupport: true,
                searchKey: "personBiking",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B4, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manBiking",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B4, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanBiking",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B5],
                isSkinToneSupport: true,
                searchKey: "personMountainBiking",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B5, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manMountainBiking",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B5, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanMountainBiking",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F938],
                isSkinToneSupport: true,
                searchKey: "personCartwheeling",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F938, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manCartwheeling",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F938, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanCartwheeling",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93C],
                isSkinToneSupport: false,
                searchKey: "peopleWrestling",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93C, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "menWrestling",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93C, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "womenWrestling",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93D],
                isSkinToneSupport: true,
                searchKey: "personPlayingWaterPolo",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93D, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manPlayingWaterPolo",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93D, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanPlayingWaterPolo",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93E],
                isSkinToneSupport: true,
                searchKey: "personPlayingHandball",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93E, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manPlayingHandball",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F93E, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanPlayingHandball",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F939],
                isSkinToneSupport: true,
                searchKey: "personJuggling",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F939, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manJuggling",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F939, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanJuggling",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D8],
                isSkinToneSupport: true,
                searchKey: "personInLotusPosition",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D8, 0x200D, 0x2642, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "manInLotusPosition",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D8, 0x200D, 0x2640, 0xFE0F],
                isSkinToneSupport: true,
                searchKey: "womanInLotusPosition",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6C0],
                isSkinToneSupport: true,
                searchKey: "personTakingBath",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6CC],
                isSkinToneSupport: false,
                searchKey: "personInBed",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9D1, 0x200D, 0x1F91D, 0x200D, 0x1F9D1],
                isSkinToneSupport: false,
                searchKey: "peopleHoldingHands",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F46D],
                isSkinToneSupport: false,
                searchKey: "womenHoldingHands",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F46B],
                isSkinToneSupport: false,
                searchKey: "womanAndManHoldingHands",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F46C],
                isSkinToneSupport: false,
                searchKey: "menHoldingHands",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F48F],
                isSkinToneSupport: false,
                searchKey: "kiss",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F48B, 0x200D, 0x1F468],
                isSkinToneSupport: false,
                searchKey: "kissWomanMan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F48B, 0x200D, 0x1F468],
                isSkinToneSupport: false,
                searchKey: "kissManMan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F48B, 0x200D, 0x1F469],
                isSkinToneSupport: false,
                searchKey: "kissWomanWoman",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F491],
                isSkinToneSupport: false,
                searchKey: "coupleWithHeart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F468],
                isSkinToneSupport: false,
                searchKey: "coupleWithHeartWomanMan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F468],
                isSkinToneSupport: false,
                searchKey: "coupleWithHeartManMan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F469],
                isSkinToneSupport: false,
                searchKey: "coupleWithHeartWomanWoman",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F46A],
                isSkinToneSupport: false,
                searchKey: "family",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManWomanBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyManWomanGirl",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManWomanGirlBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F466, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManWomanBoyBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyManWomanGirlGirl",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F468, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManManBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F468, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyManManGirl",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F468, 0x200D, 0x1F467, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManManGirlBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F468, 0x200D, 0x1F466, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManManBoyBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F468, 0x200D, 0x1F467, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyManManGirlGirl",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F469, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyWomanWomanBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F469, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyWomanWomanGirl",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyWomanWomanGirlBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F469, 0x200D, 0x1F466, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyWomanWomanBoyBoy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyWomanWomanGirlGirl",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManBoy",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F466, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManBoyBoy",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyManGirl",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F467, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyManGirlBoy",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F468, 0x200D, 0x1F467, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyManGirlGirl",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyWomanBoy",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F466, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyWomanBoyBoy",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyWomanGirl",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466],
                isSkinToneSupport: false,
                searchKey: "familyWomanGirlBoy",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F467],
                isSkinToneSupport: false,
                searchKey: "familyWomanGirlGirl",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5E3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "speakingHead",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F464],
                isSkinToneSupport: false,
                searchKey: "bustInSilhouette",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F465],
                isSkinToneSupport: false,
                searchKey: "bustsInSilhouette",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAC2],
                isSkinToneSupport: false,
                searchKey: "peopleHugging",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F463],
                isSkinToneSupport: false,
                searchKey: "footprints",
                version: 0.6
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
            
    private let natureEmojis: MCEmojiCategory = .init(
        type: .nature,
        categoryName: MCEmojiCategoryType.nature.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F435],
                isSkinToneSupport: false,
                searchKey: "monkeyFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F412],
                isSkinToneSupport: false,
                searchKey: "monkey",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F98D],
                isSkinToneSupport: false,
                searchKey: "gorilla",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A7],
                isSkinToneSupport: false,
                searchKey: "orangutan",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F436],
                isSkinToneSupport: false,
                searchKey: "dogFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F415],
                isSkinToneSupport: false,
                searchKey: "dog",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F9AE],
                isSkinToneSupport: false,
                searchKey: "guideDog",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F415, 0x200D, 0x1F9BA],
                isSkinToneSupport: false,
                searchKey: "serviceDog",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F429],
                isSkinToneSupport: false,
                searchKey: "poodle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F43A],
                isSkinToneSupport: false,
                searchKey: "wolf",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F98A],
                isSkinToneSupport: false,
                searchKey: "fox",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F99D],
                isSkinToneSupport: false,
                searchKey: "raccoon",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F431],
                isSkinToneSupport: false,
                searchKey: "catFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F408],
                isSkinToneSupport: false,
                searchKey: "cat",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F408, 0x200D, 0x2B1B],
                isSkinToneSupport: false,
                searchKey: "blackCat",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F981],
                isSkinToneSupport: false,
                searchKey: "lion",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F42F],
                isSkinToneSupport: false,
                searchKey: "tigerFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F405],
                isSkinToneSupport: false,
                searchKey: "tiger",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F406],
                isSkinToneSupport: false,
                searchKey: "leopard",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F434],
                isSkinToneSupport: false,
                searchKey: "horseFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FACE],
                isSkinToneSupport: false,
                searchKey: "moose",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1FACF],
                isSkinToneSupport: false,
                searchKey: "donkey",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F40E],
                isSkinToneSupport: false,
                searchKey: "horse",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F984],
                isSkinToneSupport: false,
                searchKey: "unicorn",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F993],
                isSkinToneSupport: false,
                searchKey: "zebra",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F98C],
                isSkinToneSupport: false,
                searchKey: "deer",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9AC],
                isSkinToneSupport: false,
                searchKey: "bison",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F42E],
                isSkinToneSupport: false,
                searchKey: "cowFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F402],
                isSkinToneSupport: false,
                searchKey: "ox",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F403],
                isSkinToneSupport: false,
                searchKey: "waterBuffalo",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F404],
                isSkinToneSupport: false,
                searchKey: "cow",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F437],
                isSkinToneSupport: false,
                searchKey: "pigFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F416],
                isSkinToneSupport: false,
                searchKey: "pig",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F417],
                isSkinToneSupport: false,
                searchKey: "boar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F43D],
                isSkinToneSupport: false,
                searchKey: "pigNose",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F40F],
                isSkinToneSupport: false,
                searchKey: "ram",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F411],
                isSkinToneSupport: false,
                searchKey: "ewe",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F410],
                isSkinToneSupport: false,
                searchKey: "goat",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F42A],
                isSkinToneSupport: false,
                searchKey: "camel",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F42B],
                isSkinToneSupport: false,
                searchKey: "twoHumpCamel",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F999],
                isSkinToneSupport: false,
                searchKey: "llama",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F992],
                isSkinToneSupport: false,
                searchKey: "giraffe",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F418],
                isSkinToneSupport: false,
                searchKey: "elephant",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9A3],
                isSkinToneSupport: false,
                searchKey: "mammoth",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F98F],
                isSkinToneSupport: false,
                searchKey: "rhinoceros",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F99B],
                isSkinToneSupport: false,
                searchKey: "hippopotamus",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F42D],
                isSkinToneSupport: false,
                searchKey: "mouseFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F401],
                isSkinToneSupport: false,
                searchKey: "mouse",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F400],
                isSkinToneSupport: false,
                searchKey: "rat",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F439],
                isSkinToneSupport: false,
                searchKey: "hamster",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F430],
                isSkinToneSupport: false,
                searchKey: "rabbitFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F407],
                isSkinToneSupport: false,
                searchKey: "rabbit",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F43F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "chipmunk",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F9AB],
                isSkinToneSupport: false,
                searchKey: "beaver",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F994],
                isSkinToneSupport: false,
                searchKey: "hedgehog",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F987],
                isSkinToneSupport: false,
                searchKey: "bat",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F43B],
                isSkinToneSupport: false,
                searchKey: "bear",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F43B, 0x200D, 0x2744, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "polarBear",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F428],
                isSkinToneSupport: false,
                searchKey: "koala",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F43C],
                isSkinToneSupport: false,
                searchKey: "panda",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9A5],
                isSkinToneSupport: false,
                searchKey: "sloth",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A6],
                isSkinToneSupport: false,
                searchKey: "otter",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A8],
                isSkinToneSupport: false,
                searchKey: "skunk",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F998],
                isSkinToneSupport: false,
                searchKey: "kangaroo",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A1],
                isSkinToneSupport: false,
                searchKey: "badger",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F43E],
                isSkinToneSupport: false,
                searchKey: "pawPrints",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F983],
                isSkinToneSupport: false,
                searchKey: "turkey",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F414],
                isSkinToneSupport: false,
                searchKey: "chicken",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F413],
                isSkinToneSupport: false,
                searchKey: "rooster",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F423],
                isSkinToneSupport: false,
                searchKey: "hatchingChick",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F424],
                isSkinToneSupport: false,
                searchKey: "babyChick",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F425],
                isSkinToneSupport: false,
                searchKey: "frontFacingBabyChick",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F426],
                isSkinToneSupport: false,
                searchKey: "bird",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F427],
                isSkinToneSupport: false,
                searchKey: "penguin",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F54A, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "dove",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F985],
                isSkinToneSupport: false,
                searchKey: "eagle",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F986],
                isSkinToneSupport: false,
                searchKey: "duck",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A2],
                isSkinToneSupport: false,
                searchKey: "swan",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F989],
                isSkinToneSupport: false,
                searchKey: "owl",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A4],
                isSkinToneSupport: false,
                searchKey: "dodo",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAB6],
                isSkinToneSupport: false,
                searchKey: "feather",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A9],
                isSkinToneSupport: false,
                searchKey: "flamingo",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F99A],
                isSkinToneSupport: false,
                searchKey: "peacock",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F99C],
                isSkinToneSupport: false,
                searchKey: "parrot",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FABD],
                isSkinToneSupport: false,
                searchKey: "wing",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F426, 0x200D, 0x2B1B],
                isSkinToneSupport: false,
                searchKey: "blackBird",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1FABF],
                isSkinToneSupport: false,
                searchKey: "goose",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F438],
                isSkinToneSupport: false,
                searchKey: "frog",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F40A],
                isSkinToneSupport: false,
                searchKey: "crocodile",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F422],
                isSkinToneSupport: false,
                searchKey: "turtle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F98E],
                isSkinToneSupport: false,
                searchKey: "lizard",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F40D],
                isSkinToneSupport: false,
                searchKey: "snake",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F432],
                isSkinToneSupport: false,
                searchKey: "dragonFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F409],
                isSkinToneSupport: false,
                searchKey: "dragon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F995],
                isSkinToneSupport: false,
                searchKey: "sauropod",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F996],
                isSkinToneSupport: false,
                searchKey: "tRex",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F433],
                isSkinToneSupport: false,
                searchKey: "spoutingWhale",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F40B],
                isSkinToneSupport: false,
                searchKey: "whale",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F42C],
                isSkinToneSupport: false,
                searchKey: "dolphin",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9AD],
                isSkinToneSupport: false,
                searchKey: "seal",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F41F],
                isSkinToneSupport: false,
                searchKey: "fish",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F420],
                isSkinToneSupport: false,
                searchKey: "tropicalFish",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F421],
                isSkinToneSupport: false,
                searchKey: "blowfish",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F988],
                isSkinToneSupport: false,
                searchKey: "shark",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F419],
                isSkinToneSupport: false,
                searchKey: "octopus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F41A],
                isSkinToneSupport: false,
                searchKey: "spiralShell",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAB8],
                isSkinToneSupport: false,
                searchKey: "coral",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FABC],
                isSkinToneSupport: false,
                searchKey: "jellyfish",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F40C],
                isSkinToneSupport: false,
                searchKey: "snail",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F98B],
                isSkinToneSupport: false,
                searchKey: "butterfly",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F41B],
                isSkinToneSupport: false,
                searchKey: "bug",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F41C],
                isSkinToneSupport: false,
                searchKey: "ant",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F41D],
                isSkinToneSupport: false,
                searchKey: "honeybee",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAB2],
                isSkinToneSupport: false,
                searchKey: "beetle",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F41E],
                isSkinToneSupport: false,
                searchKey: "ladyBeetle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F997],
                isSkinToneSupport: false,
                searchKey: "cricket",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAB3],
                isSkinToneSupport: false,
                searchKey: "cockroach",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F577, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "spider",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F578, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "spiderWeb",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F982],
                isSkinToneSupport: false,
                searchKey: "scorpion",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F99F],
                isSkinToneSupport: false,
                searchKey: "mosquito",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAB0],
                isSkinToneSupport: false,
                searchKey: "fly",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAB1],
                isSkinToneSupport: false,
                searchKey: "worm",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9A0],
                isSkinToneSupport: false,
                searchKey: "microbe",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F490],
                isSkinToneSupport: false,
                searchKey: "bouquet",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F338],
                isSkinToneSupport: false,
                searchKey: "cherryBlossom",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4AE],
                isSkinToneSupport: false,
                searchKey: "whiteFlower",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAB7],
                isSkinToneSupport: false,
                searchKey: "lotus",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F5, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rosette",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F339],
                isSkinToneSupport: false,
                searchKey: "rose",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F940],
                isSkinToneSupport: false,
                searchKey: "wiltedFlower",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F33A],
                isSkinToneSupport: false,
                searchKey: "hibiscus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F33B],
                isSkinToneSupport: false,
                searchKey: "sunflower",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F33C],
                isSkinToneSupport: false,
                searchKey: "blossom",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F337],
                isSkinToneSupport: false,
                searchKey: "tulip",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FABB],
                isSkinToneSupport: false,
                searchKey: "hyacinth",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F331],
                isSkinToneSupport: false,
                searchKey: "seedling",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAB4],
                isSkinToneSupport: false,
                searchKey: "pottedPlant",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F332],
                isSkinToneSupport: false,
                searchKey: "evergreenTree",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F333],
                isSkinToneSupport: false,
                searchKey: "deciduousTree",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F334],
                isSkinToneSupport: false,
                searchKey: "palmTree",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F335],
                isSkinToneSupport: false,
                searchKey: "cactus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F33E],
                isSkinToneSupport: false,
                searchKey: "sheafOfRice",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F33F],
                isSkinToneSupport: false,
                searchKey: "herb",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2618, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "shamrock",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F340],
                isSkinToneSupport: false,
                searchKey: "fourLeafClover",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F341],
                isSkinToneSupport: false,
                searchKey: "mapleLeaf",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F342],
                isSkinToneSupport: false,
                searchKey: "fallenLeaf",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F343],
                isSkinToneSupport: false,
                searchKey: "leafFlutteringInWind",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAB9],
                isSkinToneSupport: false,
                searchKey: "emptyNest",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FABA],
                isSkinToneSupport: false,
                searchKey: "nestWithEggs",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F344],
                isSkinToneSupport: false,
                searchKey: "mushroom",
                version: 0.6
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
    
    private let foodAndDrinkEmojis: MCEmojiCategory = .init(
        type: .foodAndDrink,
        categoryName: MCEmojiCategoryType.foodAndDrink.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F347],
                isSkinToneSupport: false,
                searchKey: "grapes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F348],
                isSkinToneSupport: false,
                searchKey: "melon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F349],
                isSkinToneSupport: false,
                searchKey: "watermelon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F34A],
                isSkinToneSupport: false,
                searchKey: "tangerine",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F34B],
                isSkinToneSupport: false,
                searchKey: "lemon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F34C],
                isSkinToneSupport: false,
                searchKey: "banana",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F34D],
                isSkinToneSupport: false,
                searchKey: "pineapple",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F96D],
                isSkinToneSupport: false,
                searchKey: "mango",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F34E],
                isSkinToneSupport: false,
                searchKey: "redApple",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F34F],
                isSkinToneSupport: false,
                searchKey: "greenApple",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F350],
                isSkinToneSupport: false,
                searchKey: "pear",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F351],
                isSkinToneSupport: false,
                searchKey: "peach",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F352],
                isSkinToneSupport: false,
                searchKey: "cherries",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F353],
                isSkinToneSupport: false,
                searchKey: "strawberry",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAD0],
                isSkinToneSupport: false,
                searchKey: "blueberries",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F95D],
                isSkinToneSupport: false,
                searchKey: "kiwiFruit",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F345],
                isSkinToneSupport: false,
                searchKey: "tomato",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAD2],
                isSkinToneSupport: false,
                searchKey: "olive",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F965],
                isSkinToneSupport: false,
                searchKey: "coconut",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F951],
                isSkinToneSupport: false,
                searchKey: "avocado",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F346],
                isSkinToneSupport: false,
                searchKey: "eggplant",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F954],
                isSkinToneSupport: false,
                searchKey: "potato",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F955],
                isSkinToneSupport: false,
                searchKey: "carrot",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F33D],
                isSkinToneSupport: false,
                searchKey: "earOfCorn",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F336, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "hotPepper",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1FAD1],
                isSkinToneSupport: false,
                searchKey: "bellPepper",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F952],
                isSkinToneSupport: false,
                searchKey: "cucumber",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F96C],
                isSkinToneSupport: false,
                searchKey: "leafyGreen",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F966],
                isSkinToneSupport: false,
                searchKey: "broccoli",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C4],
                isSkinToneSupport: false,
                searchKey: "garlic",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C5],
                isSkinToneSupport: false,
                searchKey: "onion",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F95C],
                isSkinToneSupport: false,
                searchKey: "peanuts",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAD8],
                isSkinToneSupport: false,
                searchKey: "beans",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F330],
                isSkinToneSupport: false,
                searchKey: "chestnut",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FADA],
                isSkinToneSupport: false,
                searchKey: "gingerRoot",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1FADB],
                isSkinToneSupport: false,
                searchKey: "peaPod",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F35E],
                isSkinToneSupport: false,
                searchKey: "bread",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F950],
                isSkinToneSupport: false,
                searchKey: "croissant",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F956],
                isSkinToneSupport: false,
                searchKey: "baguetteBread",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAD3],
                isSkinToneSupport: false,
                searchKey: "flatbread",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F968],
                isSkinToneSupport: false,
                searchKey: "pretzel",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F96F],
                isSkinToneSupport: false,
                searchKey: "bagel",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F95E],
                isSkinToneSupport: false,
                searchKey: "pancakes",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C7],
                isSkinToneSupport: false,
                searchKey: "waffle",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C0],
                isSkinToneSupport: false,
                searchKey: "cheeseWedge",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F356],
                isSkinToneSupport: false,
                searchKey: "meatOnBone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F357],
                isSkinToneSupport: false,
                searchKey: "poultryLeg",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F969],
                isSkinToneSupport: false,
                searchKey: "cutOfMeat",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F953],
                isSkinToneSupport: false,
                searchKey: "bacon",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F354],
                isSkinToneSupport: false,
                searchKey: "hamburger",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F35F],
                isSkinToneSupport: false,
                searchKey: "frenchFries",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F355],
                isSkinToneSupport: false,
                searchKey: "pizza",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F32D],
                isSkinToneSupport: false,
                searchKey: "hotDog",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F96A],
                isSkinToneSupport: false,
                searchKey: "sandwich",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F32E],
                isSkinToneSupport: false,
                searchKey: "taco",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F32F],
                isSkinToneSupport: false,
                searchKey: "burrito",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAD4],
                isSkinToneSupport: false,
                searchKey: "tamale",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F959],
                isSkinToneSupport: false,
                searchKey: "stuffedFlatbread",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C6],
                isSkinToneSupport: false,
                searchKey: "falafel",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F95A],
                isSkinToneSupport: false,
                searchKey: "egg",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F373],
                isSkinToneSupport: false,
                searchKey: "cooking",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F958],
                isSkinToneSupport: false,
                searchKey: "shallowPanOfFood",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F372],
                isSkinToneSupport: false,
                searchKey: "potOfFood",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAD5],
                isSkinToneSupport: false,
                searchKey: "fondue",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F963],
                isSkinToneSupport: false,
                searchKey: "bowlWithSpoon",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F957],
                isSkinToneSupport: false,
                searchKey: "greenSalad",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F37F],
                isSkinToneSupport: false,
                searchKey: "popcorn",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C8],
                isSkinToneSupport: false,
                searchKey: "butter",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C2],
                isSkinToneSupport: false,
                searchKey: "salt",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F96B],
                isSkinToneSupport: false,
                searchKey: "cannedFood",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F371],
                isSkinToneSupport: false,
                searchKey: "bentoBox",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F358],
                isSkinToneSupport: false,
                searchKey: "riceCracker",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F359],
                isSkinToneSupport: false,
                searchKey: "riceBall",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F35A],
                isSkinToneSupport: false,
                searchKey: "cookedRice",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F35B],
                isSkinToneSupport: false,
                searchKey: "curryRice",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F35C],
                isSkinToneSupport: false,
                searchKey: "steamingBowl",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F35D],
                isSkinToneSupport: false,
                searchKey: "spaghetti",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F360],
                isSkinToneSupport: false,
                searchKey: "roastedSweetPotato",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F362],
                isSkinToneSupport: false,
                searchKey: "oden",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F363],
                isSkinToneSupport: false,
                searchKey: "sushi",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F364],
                isSkinToneSupport: false,
                searchKey: "friedShrimp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F365],
                isSkinToneSupport: false,
                searchKey: "fishCakeWithSwirl",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F96E],
                isSkinToneSupport: false,
                searchKey: "moonCake",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F361],
                isSkinToneSupport: false,
                searchKey: "dango",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F95F],
                isSkinToneSupport: false,
                searchKey: "dumpling",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F960],
                isSkinToneSupport: false,
                searchKey: "fortuneCookie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F961],
                isSkinToneSupport: false,
                searchKey: "takeoutBox",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F980],
                isSkinToneSupport: false,
                searchKey: "crab",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F99E],
                isSkinToneSupport: false,
                searchKey: "lobster",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F990],
                isSkinToneSupport: false,
                searchKey: "shrimp",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F991],
                isSkinToneSupport: false,
                searchKey: "squid",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9AA],
                isSkinToneSupport: false,
                searchKey: "oyster",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F366],
                isSkinToneSupport: false,
                searchKey: "softIceCream",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F367],
                isSkinToneSupport: false,
                searchKey: "shavedIce",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F368],
                isSkinToneSupport: false,
                searchKey: "iceCream",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F369],
                isSkinToneSupport: false,
                searchKey: "doughnut",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F36A],
                isSkinToneSupport: false,
                searchKey: "cookie",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F382],
                isSkinToneSupport: false,
                searchKey: "birthdayCake",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F370],
                isSkinToneSupport: false,
                searchKey: "shortcake",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9C1],
                isSkinToneSupport: false,
                searchKey: "cupcake",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F967],
                isSkinToneSupport: false,
                searchKey: "pie",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F36B],
                isSkinToneSupport: false,
                searchKey: "chocolateBar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F36C],
                isSkinToneSupport: false,
                searchKey: "candy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F36D],
                isSkinToneSupport: false,
                searchKey: "lollipop",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F36E],
                isSkinToneSupport: false,
                searchKey: "custard",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F36F],
                isSkinToneSupport: false,
                searchKey: "honeyPot",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F37C],
                isSkinToneSupport: false,
                searchKey: "babyBottle",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F95B],
                isSkinToneSupport: false,
                searchKey: "glassOfMilk",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x2615],
                isSkinToneSupport: false,
                searchKey: "hotBeverage",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAD6],
                isSkinToneSupport: false,
                searchKey: "teapot",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F375],
                isSkinToneSupport: false,
                searchKey: "teacupWithoutHandle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F376],
                isSkinToneSupport: false,
                searchKey: "sake",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F37E],
                isSkinToneSupport: false,
                searchKey: "bottleWithPoppingCork",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F377],
                isSkinToneSupport: false,
                searchKey: "wineGlass",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F378],
                isSkinToneSupport: false,
                searchKey: "cocktailGlass",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F379],
                isSkinToneSupport: false,
                searchKey: "tropicalDrink",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F37A],
                isSkinToneSupport: false,
                searchKey: "beerMug",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F37B],
                isSkinToneSupport: false,
                searchKey: "clinkingBeerMugs",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F942],
                isSkinToneSupport: false,
                searchKey: "clinkingGlasses",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F943],
                isSkinToneSupport: false,
                searchKey: "tumblerGlass",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAD7],
                isSkinToneSupport: false,
                searchKey: "pouringLiquid",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F964],
                isSkinToneSupport: false,
                searchKey: "cupWithStraw",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CB],
                isSkinToneSupport: false,
                searchKey: "bubbleTea",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C3],
                isSkinToneSupport: false,
                searchKey: "beverageBox",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9C9],
                isSkinToneSupport: false,
                searchKey: "mate",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9CA],
                isSkinToneSupport: false,
                searchKey: "ice",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F962],
                isSkinToneSupport: false,
                searchKey: "chopsticks",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F37D, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "forkAndKnifeWithPlate",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F374],
                isSkinToneSupport: false,
                searchKey: "forkAndKnife",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F944],
                isSkinToneSupport: false,
                searchKey: "spoon",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F52A],
                isSkinToneSupport: false,
                searchKey: "kitchenKnife",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAD9],
                isSkinToneSupport: false,
                searchKey: "jar",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3FA],
                isSkinToneSupport: false,
                searchKey: "amphora",
                version: 1.0
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
            
    private let activityEmojis: MCEmojiCategory = .init(
        type: .activity,
        categoryName: MCEmojiCategoryType.activity.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F383],
                isSkinToneSupport: false,
                searchKey: "jackOLantern",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F384],
                isSkinToneSupport: false,
                searchKey: "christmasTree",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F386],
                isSkinToneSupport: false,
                searchKey: "fireworks",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F387],
                isSkinToneSupport: false,
                searchKey: "sparkler",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9E8],
                isSkinToneSupport: false,
                searchKey: "firecracker",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x2728],
                isSkinToneSupport: false,
                searchKey: "sparkles",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F388],
                isSkinToneSupport: false,
                searchKey: "balloon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F389],
                isSkinToneSupport: false,
                searchKey: "partyPopper",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F38A],
                isSkinToneSupport: false,
                searchKey: "confettiBall",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F38B],
                isSkinToneSupport: false,
                searchKey: "tanabataTree",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F38D],
                isSkinToneSupport: false,
                searchKey: "pineDecoration",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F38E],
                isSkinToneSupport: false,
                searchKey: "japaneseDolls",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F38F],
                isSkinToneSupport: false,
                searchKey: "carpStreamer",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F390],
                isSkinToneSupport: false,
                searchKey: "windChime",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F391],
                isSkinToneSupport: false,
                searchKey: "moonViewingCeremony",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9E7],
                isSkinToneSupport: false,
                searchKey: "redEnvelope",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F380],
                isSkinToneSupport: false,
                searchKey: "ribbon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F381],
                isSkinToneSupport: false,
                searchKey: "wrappedGift",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F397, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "reminderRibbon",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F39F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "admissionTickets",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3AB],
                isSkinToneSupport: false,
                searchKey: "ticket",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F396, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "militaryMedal",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3C6],
                isSkinToneSupport: false,
                searchKey: "trophy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3C5],
                isSkinToneSupport: false,
                searchKey: "sportsMedal",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F947],
                isSkinToneSupport: false,
                searchKey: "1stPlaceMedal",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F948],
                isSkinToneSupport: false,
                searchKey: "2ndPlaceMedal",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F949],
                isSkinToneSupport: false,
                searchKey: "3rdPlaceMedal",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x26BD],
                isSkinToneSupport: false,
                searchKey: "soccerBall",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26BE],
                isSkinToneSupport: false,
                searchKey: "baseball",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F94E],
                isSkinToneSupport: false,
                searchKey: "softball",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C0],
                isSkinToneSupport: false,
                searchKey: "basketball",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3D0],
                isSkinToneSupport: false,
                searchKey: "volleyball",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3C8],
                isSkinToneSupport: false,
                searchKey: "americanFootball",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3C9],
                isSkinToneSupport: false,
                searchKey: "rugbyFootball",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3BE],
                isSkinToneSupport: false,
                searchKey: "tennis",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F94F],
                isSkinToneSupport: false,
                searchKey: "flyingDisc",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3B3],
                isSkinToneSupport: false,
                searchKey: "bowling",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3CF],
                isSkinToneSupport: false,
                searchKey: "cricketGame",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3D1],
                isSkinToneSupport: false,
                searchKey: "fieldHockey",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3D2],
                isSkinToneSupport: false,
                searchKey: "iceHockey",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F94D],
                isSkinToneSupport: false,
                searchKey: "lacrosse",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3D3],
                isSkinToneSupport: false,
                searchKey: "pingPong",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F8],
                isSkinToneSupport: false,
                searchKey: "badminton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F94A],
                isSkinToneSupport: false,
                searchKey: "boxingGlove",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F94B],
                isSkinToneSupport: false,
                searchKey: "martialArtsUniform",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F945],
                isSkinToneSupport: false,
                searchKey: "goalNet",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x26F3],
                isSkinToneSupport: false,
                searchKey: "flagInHole",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26F8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "iceSkate",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3A3],
                isSkinToneSupport: false,
                searchKey: "fishingPole",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F93F],
                isSkinToneSupport: false,
                searchKey: "divingMask",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3BD],
                isSkinToneSupport: false,
                searchKey: "runningShirt",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3BF],
                isSkinToneSupport: false,
                searchKey: "skis",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6F7],
                isSkinToneSupport: false,
                searchKey: "sled",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F94C],
                isSkinToneSupport: false,
                searchKey: "curlingStone",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3AF],
                isSkinToneSupport: false,
                searchKey: "bullseye",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA80],
                isSkinToneSupport: false,
                searchKey: "yoYo",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA81],
                isSkinToneSupport: false,
                searchKey: "kite",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F52B],
                isSkinToneSupport: false,
                searchKey: "waterPistol",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B1],
                isSkinToneSupport: false,
                searchKey: "pool8Ball",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F52E],
                isSkinToneSupport: false,
                searchKey: "crystalBall",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA84],
                isSkinToneSupport: false,
                searchKey: "magicWand",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3AE],
                isSkinToneSupport: false,
                searchKey: "videoGame",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F579, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "joystick",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3B0],
                isSkinToneSupport: false,
                searchKey: "slotMachine",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B2],
                isSkinToneSupport: false,
                searchKey: "gameDie",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9E9],
                isSkinToneSupport: false,
                searchKey: "puzzlePiece",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F8],
                isSkinToneSupport: false,
                searchKey: "teddyBear",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA85],
                isSkinToneSupport: false,
                searchKey: "piñata",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA9],
                isSkinToneSupport: false,
                searchKey: "mirrorBall",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA86],
                isSkinToneSupport: false,
                searchKey: "nestingDolls",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x2660, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "spadeSuit",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2665, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "heartSuit",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2666, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "diamondSuit",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2663, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "clubSuit",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x265F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "chessPawn",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F0CF],
                isSkinToneSupport: false,
                searchKey: "joker",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F004],
                isSkinToneSupport: false,
                searchKey: "mahjongRedDragon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B4],
                isSkinToneSupport: false,
                searchKey: "flowerPlayingCards",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3AD],
                isSkinToneSupport: false,
                searchKey: "performingArts",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5BC, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "framedPicture",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3A8],
                isSkinToneSupport: false,
                searchKey: "artistPalette",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9F5],
                isSkinToneSupport: false,
                searchKey: "thread",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA1],
                isSkinToneSupport: false,
                searchKey: "sewingNeedle",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F6],
                isSkinToneSupport: false,
                searchKey: "yarn",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA2],
                isSkinToneSupport: false,
                searchKey: "knot",
                version: 13.0
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
    
    private let travelAndPlacesEmojis: MCEmojiCategory = .init(
        type: .travelAndPlaces,
        categoryName: MCEmojiCategoryType.travelAndPlaces.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F30D],
                isSkinToneSupport: false,
                searchKey: "globeShowingEuropeAfrica",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F30E],
                isSkinToneSupport: false,
                searchKey: "globeShowingAmericas",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F30F],
                isSkinToneSupport: false,
                searchKey: "globeShowingAsiaAustralia",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F310],
                isSkinToneSupport: false,
                searchKey: "globeWithMeridians",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5FA, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "worldMap",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5FE],
                isSkinToneSupport: false,
                searchKey: "mapOfJapan",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9ED],
                isSkinToneSupport: false,
                searchKey: "compass",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3D4, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "snowCappedMountain",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x26F0, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "mountain",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F30B],
                isSkinToneSupport: false,
                searchKey: "volcano",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5FB],
                isSkinToneSupport: false,
                searchKey: "mountFuji",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3D5, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "camping",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3D6, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "beachWithUmbrella",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3DC, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "desert",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3DD, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "desertIsland",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3DE, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "nationalPark",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3DF, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "stadium",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3DB, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "classicalBuilding",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3D7, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "buildingConstruction",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F9F1],
                isSkinToneSupport: false,
                searchKey: "brick",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA8],
                isSkinToneSupport: false,
                searchKey: "rock",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAB5],
                isSkinToneSupport: false,
                searchKey: "wood",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6D6],
                isSkinToneSupport: false,
                searchKey: "hut",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3D8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "houses",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3DA, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "derelictHouse",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3E0],
                isSkinToneSupport: false,
                searchKey: "house",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E1],
                isSkinToneSupport: false,
                searchKey: "houseWithGarden",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E2],
                isSkinToneSupport: false,
                searchKey: "officeBuilding",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E3],
                isSkinToneSupport: false,
                searchKey: "japanesePostOffice",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E4],
                isSkinToneSupport: false,
                searchKey: "postOffice",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3E5],
                isSkinToneSupport: false,
                searchKey: "hospital",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E6],
                isSkinToneSupport: false,
                searchKey: "bank",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E8],
                isSkinToneSupport: false,
                searchKey: "hotel",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3E9],
                isSkinToneSupport: false,
                searchKey: "loveHotel",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3EA],
                isSkinToneSupport: false,
                searchKey: "convenienceStore",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3EB],
                isSkinToneSupport: false,
                searchKey: "school",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3EC],
                isSkinToneSupport: false,
                searchKey: "departmentStore",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3ED],
                isSkinToneSupport: false,
                searchKey: "factory",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3EF],
                isSkinToneSupport: false,
                searchKey: "japaneseCastle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3F0],
                isSkinToneSupport: false,
                searchKey: "castle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F492],
                isSkinToneSupport: false,
                searchKey: "wedding",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5FC],
                isSkinToneSupport: false,
                searchKey: "tokyoTower",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5FD],
                isSkinToneSupport: false,
                searchKey: "statueOfLiberty",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26EA],
                isSkinToneSupport: false,
                searchKey: "church",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F54C],
                isSkinToneSupport: false,
                searchKey: "mosque",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6D5],
                isSkinToneSupport: false,
                searchKey: "hinduTemple",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F54D],
                isSkinToneSupport: false,
                searchKey: "synagogue",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x26E9, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "shintoShrine",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F54B],
                isSkinToneSupport: false,
                searchKey: "kaaba",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x26F2],
                isSkinToneSupport: false,
                searchKey: "fountain",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26FA],
                isSkinToneSupport: false,
                searchKey: "tent",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F301],
                isSkinToneSupport: false,
                searchKey: "foggy",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F303],
                isSkinToneSupport: false,
                searchKey: "nightWithStars",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3D9, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cityscape",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F304],
                isSkinToneSupport: false,
                searchKey: "sunriseOverMountains",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F305],
                isSkinToneSupport: false,
                searchKey: "sunrise",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F306],
                isSkinToneSupport: false,
                searchKey: "cityscapeAtDusk",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F307],
                isSkinToneSupport: false,
                searchKey: "sunset",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F309],
                isSkinToneSupport: false,
                searchKey: "bridgeAtNight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2668, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "hotSprings",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3A0],
                isSkinToneSupport: false,
                searchKey: "carouselHorse",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6DD],
                isSkinToneSupport: false,
                searchKey: "playgroundSlide",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3A1],
                isSkinToneSupport: false,
                searchKey: "ferrisWheel",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3A2],
                isSkinToneSupport: false,
                searchKey: "rollerCoaster",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F488],
                isSkinToneSupport: false,
                searchKey: "barberPole",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3AA],
                isSkinToneSupport: false,
                searchKey: "circusTent",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F682],
                isSkinToneSupport: false,
                searchKey: "locomotive",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F683],
                isSkinToneSupport: false,
                searchKey: "railwayCar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F684],
                isSkinToneSupport: false,
                searchKey: "highSpeedTrain",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F685],
                isSkinToneSupport: false,
                searchKey: "bulletTrain",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F686],
                isSkinToneSupport: false,
                searchKey: "train",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F687],
                isSkinToneSupport: false,
                searchKey: "metro",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F688],
                isSkinToneSupport: false,
                searchKey: "lightRail",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F689],
                isSkinToneSupport: false,
                searchKey: "station",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F68A],
                isSkinToneSupport: false,
                searchKey: "tram",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F69D],
                isSkinToneSupport: false,
                searchKey: "monorail",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F69E],
                isSkinToneSupport: false,
                searchKey: "mountainRailway",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F68B],
                isSkinToneSupport: false,
                searchKey: "tramCar",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F68C],
                isSkinToneSupport: false,
                searchKey: "bus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F68D],
                isSkinToneSupport: false,
                searchKey: "oncomingBus",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F68E],
                isSkinToneSupport: false,
                searchKey: "trolleybus",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F690],
                isSkinToneSupport: false,
                searchKey: "minibus",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F691],
                isSkinToneSupport: false,
                searchKey: "ambulance",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F692],
                isSkinToneSupport: false,
                searchKey: "fireEngine",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F693],
                isSkinToneSupport: false,
                searchKey: "policeCar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F694],
                isSkinToneSupport: false,
                searchKey: "oncomingPoliceCar",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F695],
                isSkinToneSupport: false,
                searchKey: "taxi",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F696],
                isSkinToneSupport: false,
                searchKey: "oncomingTaxi",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F697],
                isSkinToneSupport: false,
                searchKey: "automobile",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F698],
                isSkinToneSupport: false,
                searchKey: "oncomingAutomobile",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F699],
                isSkinToneSupport: false,
                searchKey: "sportUtilityVehicle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6FB],
                isSkinToneSupport: false,
                searchKey: "pickupTruck",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F69A],
                isSkinToneSupport: false,
                searchKey: "deliveryTruck",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F69B],
                isSkinToneSupport: false,
                searchKey: "articulatedLorry",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F69C],
                isSkinToneSupport: false,
                searchKey: "tractor",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3CE, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "racingCar",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3CD, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "motorcycle",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6F5],
                isSkinToneSupport: false,
                searchKey: "motorScooter",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9BD],
                isSkinToneSupport: false,
                searchKey: "manualWheelchair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9BC],
                isSkinToneSupport: false,
                searchKey: "motorizedWheelchair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6FA],
                isSkinToneSupport: false,
                searchKey: "autoRickshaw",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B2],
                isSkinToneSupport: false,
                searchKey: "bicycle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6F4],
                isSkinToneSupport: false,
                searchKey: "kickScooter",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6F9],
                isSkinToneSupport: false,
                searchKey: "skateboard",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6FC],
                isSkinToneSupport: false,
                searchKey: "rollerSkate",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F68F],
                isSkinToneSupport: false,
                searchKey: "busStop",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6E3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "motorway",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6E4, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "railwayTrack",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6E2, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "oilDrum",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x26FD],
                isSkinToneSupport: false,
                searchKey: "fuelPump",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6DE],
                isSkinToneSupport: false,
                searchKey: "wheel",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A8],
                isSkinToneSupport: false,
                searchKey: "policeCarLight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6A5],
                isSkinToneSupport: false,
                searchKey: "horizontalTrafficLight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6A6],
                isSkinToneSupport: false,
                searchKey: "verticalTrafficLight",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6D1],
                isSkinToneSupport: false,
                searchKey: "stopSign",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A7],
                isSkinToneSupport: false,
                searchKey: "construction",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2693],
                isSkinToneSupport: false,
                searchKey: "anchor",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6DF],
                isSkinToneSupport: false,
                searchKey: "ringBuoy",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x26F5],
                isSkinToneSupport: false,
                searchKey: "sailboat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6F6],
                isSkinToneSupport: false,
                searchKey: "canoe",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A4],
                isSkinToneSupport: false,
                searchKey: "speedboat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6F3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "passengerShip",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x26F4, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "ferry",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6E5, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "motorBoat",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6A2],
                isSkinToneSupport: false,
                searchKey: "ship",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2708, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "airplane",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6E9, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "smallAirplane",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6EB],
                isSkinToneSupport: false,
                searchKey: "airplaneDeparture",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6EC],
                isSkinToneSupport: false,
                searchKey: "airplaneArrival",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA82],
                isSkinToneSupport: false,
                searchKey: "parachute",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4BA],
                isSkinToneSupport: false,
                searchKey: "seat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F681],
                isSkinToneSupport: false,
                searchKey: "helicopter",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F69F],
                isSkinToneSupport: false,
                searchKey: "suspensionRailway",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A0],
                isSkinToneSupport: false,
                searchKey: "mountainCableway",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6A1],
                isSkinToneSupport: false,
                searchKey: "aerialTramway",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6F0, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "satellite",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F680],
                isSkinToneSupport: false,
                searchKey: "rocket",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6F8],
                isSkinToneSupport: false,
                searchKey: "flyingSaucer",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6CE, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "bellhopBell",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F9F3],
                isSkinToneSupport: false,
                searchKey: "luggage",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x231B],
                isSkinToneSupport: false,
                searchKey: "hourglassDone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23F3],
                isSkinToneSupport: false,
                searchKey: "hourglassNotDone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x231A],
                isSkinToneSupport: false,
                searchKey: "watch",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23F0],
                isSkinToneSupport: false,
                searchKey: "alarmClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23F1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "stopwatch",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x23F2, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "timerClock",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F570, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "mantelpieceClock",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F55B],
                isSkinToneSupport: false,
                searchKey: "twelveOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F567],
                isSkinToneSupport: false,
                searchKey: "twelveThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F550],
                isSkinToneSupport: false,
                searchKey: "oneOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F55C],
                isSkinToneSupport: false,
                searchKey: "oneThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F551],
                isSkinToneSupport: false,
                searchKey: "twoOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F55D],
                isSkinToneSupport: false,
                searchKey: "twoThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F552],
                isSkinToneSupport: false,
                searchKey: "threeOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F55E],
                isSkinToneSupport: false,
                searchKey: "threeThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F553],
                isSkinToneSupport: false,
                searchKey: "fourOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F55F],
                isSkinToneSupport: false,
                searchKey: "fourThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F554],
                isSkinToneSupport: false,
                searchKey: "fiveOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F560],
                isSkinToneSupport: false,
                searchKey: "fiveThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F555],
                isSkinToneSupport: false,
                searchKey: "sixOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F561],
                isSkinToneSupport: false,
                searchKey: "sixThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F556],
                isSkinToneSupport: false,
                searchKey: "sevenOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F562],
                isSkinToneSupport: false,
                searchKey: "sevenThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F557],
                isSkinToneSupport: false,
                searchKey: "eightOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F563],
                isSkinToneSupport: false,
                searchKey: "eightThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F558],
                isSkinToneSupport: false,
                searchKey: "nineOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F564],
                isSkinToneSupport: false,
                searchKey: "nineThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F559],
                isSkinToneSupport: false,
                searchKey: "tenOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F565],
                isSkinToneSupport: false,
                searchKey: "tenThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F55A],
                isSkinToneSupport: false,
                searchKey: "elevenOClock",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F566],
                isSkinToneSupport: false,
                searchKey: "elevenThirty",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F311],
                isSkinToneSupport: false,
                searchKey: "newMoon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F312],
                isSkinToneSupport: false,
                searchKey: "waxingCrescentMoon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F313],
                isSkinToneSupport: false,
                searchKey: "firstQuarterMoon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F314],
                isSkinToneSupport: false,
                searchKey: "waxingGibbousMoon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F315],
                isSkinToneSupport: false,
                searchKey: "fullMoon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F316],
                isSkinToneSupport: false,
                searchKey: "waningGibbousMoon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F317],
                isSkinToneSupport: false,
                searchKey: "lastQuarterMoon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F318],
                isSkinToneSupport: false,
                searchKey: "waningCrescentMoon",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F319],
                isSkinToneSupport: false,
                searchKey: "crescentMoon",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F31A],
                isSkinToneSupport: false,
                searchKey: "newMoonFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F31B],
                isSkinToneSupport: false,
                searchKey: "firstQuarterMoonFace",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F31C],
                isSkinToneSupport: false,
                searchKey: "lastQuarterMoonFace",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F321, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "thermometer",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2600, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "sun",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F31D],
                isSkinToneSupport: false,
                searchKey: "fullMoonFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F31E],
                isSkinToneSupport: false,
                searchKey: "sunWithFace",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA90],
                isSkinToneSupport: false,
                searchKey: "ringedPlanet",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x2B50],
                isSkinToneSupport: false,
                searchKey: "star",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F31F],
                isSkinToneSupport: false,
                searchKey: "glowingStar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F320],
                isSkinToneSupport: false,
                searchKey: "shootingStar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F30C],
                isSkinToneSupport: false,
                searchKey: "milkyWay",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2601, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cloud",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26C5],
                isSkinToneSupport: false,
                searchKey: "sunBehindCloud",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26C8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cloudWithLightningAndRain",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F324, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "sunBehindSmallCloud",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F325, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "sunBehindLargeCloud",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F326, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "sunBehindRainCloud",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F327, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cloudWithRain",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F328, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cloudWithSnow",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F329, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cloudWithLightning",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F32A, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "tornado",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F32B, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "fog",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F32C, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "windFace",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F300],
                isSkinToneSupport: false,
                searchKey: "cyclone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F308],
                isSkinToneSupport: false,
                searchKey: "rainbow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F302],
                isSkinToneSupport: false,
                searchKey: "closedUmbrella",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2602, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "umbrella",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2614],
                isSkinToneSupport: false,
                searchKey: "umbrellaWithRainDrops",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26F1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "umbrellaOnGround",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x26A1],
                isSkinToneSupport: false,
                searchKey: "highVoltage",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2744, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "snowflake",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2603, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "snowman",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x26C4],
                isSkinToneSupport: false,
                searchKey: "snowmanWithoutSnow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2604, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "comet",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F525],
                isSkinToneSupport: false,
                searchKey: "fire",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4A7],
                isSkinToneSupport: false,
                searchKey: "droplet",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F30A],
                isSkinToneSupport: false,
                searchKey: "waterWave",
                version: 0.6
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
    
    private let objectEmojis: MCEmojiCategory = .init(
        type: .objects,
        categoryName: MCEmojiCategoryType.objects.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F453],
                isSkinToneSupport: false,
                searchKey: "glasses",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F576, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "sunglasses",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F97D],
                isSkinToneSupport: false,
                searchKey: "goggles",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F97C],
                isSkinToneSupport: false,
                searchKey: "labCoat",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9BA],
                isSkinToneSupport: false,
                searchKey: "safetyVest",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F454],
                isSkinToneSupport: false,
                searchKey: "necktie",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F455],
                isSkinToneSupport: false,
                searchKey: "tShirt",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F456],
                isSkinToneSupport: false,
                searchKey: "jeans",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9E3],
                isSkinToneSupport: false,
                searchKey: "scarf",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9E4],
                isSkinToneSupport: false,
                searchKey: "gloves",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9E5],
                isSkinToneSupport: false,
                searchKey: "coat",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9E6],
                isSkinToneSupport: false,
                searchKey: "socks",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F457],
                isSkinToneSupport: false,
                searchKey: "dress",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F458],
                isSkinToneSupport: false,
                searchKey: "kimono",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F97B],
                isSkinToneSupport: false,
                searchKey: "sari",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA71],
                isSkinToneSupport: false,
                searchKey: "onePieceSwimsuit",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA72],
                isSkinToneSupport: false,
                searchKey: "briefs",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA73],
                isSkinToneSupport: false,
                searchKey: "shorts",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F459],
                isSkinToneSupport: false,
                searchKey: "bikini",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F45A],
                isSkinToneSupport: false,
                searchKey: "womanSClothes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAAD],
                isSkinToneSupport: false,
                searchKey: "foldingHandFan",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F45B],
                isSkinToneSupport: false,
                searchKey: "purse",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F45C],
                isSkinToneSupport: false,
                searchKey: "handbag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F45D],
                isSkinToneSupport: false,
                searchKey: "clutchBag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6CD, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "shoppingBags",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F392],
                isSkinToneSupport: false,
                searchKey: "backpack",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA74],
                isSkinToneSupport: false,
                searchKey: "thongSandal",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F45E],
                isSkinToneSupport: false,
                searchKey: "manSShoe",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F45F],
                isSkinToneSupport: false,
                searchKey: "runningShoe",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F97E],
                isSkinToneSupport: false,
                searchKey: "hikingBoot",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F97F],
                isSkinToneSupport: false,
                searchKey: "flatShoe",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F460],
                isSkinToneSupport: false,
                searchKey: "highHeeledShoe",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F461],
                isSkinToneSupport: false,
                searchKey: "womanSSandal",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA70],
                isSkinToneSupport: false,
                searchKey: "balletShoes",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F462],
                isSkinToneSupport: false,
                searchKey: "womanSBoot",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAAE],
                isSkinToneSupport: false,
                searchKey: "hairPick",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F451],
                isSkinToneSupport: false,
                searchKey: "crown",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F452],
                isSkinToneSupport: false,
                searchKey: "womanSHat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3A9],
                isSkinToneSupport: false,
                searchKey: "topHat",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F393],
                isSkinToneSupport: false,
                searchKey: "graduationCap",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9E2],
                isSkinToneSupport: false,
                searchKey: "billedCap",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA96],
                isSkinToneSupport: false,
                searchKey: "militaryHelmet",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x26D1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rescueWorkerSHelmet",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4FF],
                isSkinToneSupport: false,
                searchKey: "prayerBeads",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F484],
                isSkinToneSupport: false,
                searchKey: "lipstick",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F48D],
                isSkinToneSupport: false,
                searchKey: "ring",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F48E],
                isSkinToneSupport: false,
                searchKey: "gemStone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F507],
                isSkinToneSupport: false,
                searchKey: "mutedSpeaker",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F508],
                isSkinToneSupport: false,
                searchKey: "speakerLowVolume",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F509],
                isSkinToneSupport: false,
                searchKey: "speakerMediumVolume",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F50A],
                isSkinToneSupport: false,
                searchKey: "speakerHighVolume",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E2],
                isSkinToneSupport: false,
                searchKey: "loudspeaker",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E3],
                isSkinToneSupport: false,
                searchKey: "megaphone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4EF],
                isSkinToneSupport: false,
                searchKey: "postalHorn",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F514],
                isSkinToneSupport: false,
                searchKey: "bell",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F515],
                isSkinToneSupport: false,
                searchKey: "bellWithSlash",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3BC],
                isSkinToneSupport: false,
                searchKey: "musicalScore",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B5],
                isSkinToneSupport: false,
                searchKey: "musicalNote",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B6],
                isSkinToneSupport: false,
                searchKey: "musicalNotes",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F399, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "studioMicrophone",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F39A, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "levelSlider",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F39B, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "controlKnobs",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3A4],
                isSkinToneSupport: false,
                searchKey: "microphone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3A7],
                isSkinToneSupport: false,
                searchKey: "headphone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4FB],
                isSkinToneSupport: false,
                searchKey: "radio",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B7],
                isSkinToneSupport: false,
                searchKey: "saxophone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA97],
                isSkinToneSupport: false,
                searchKey: "accordion",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3B8],
                isSkinToneSupport: false,
                searchKey: "guitar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3B9],
                isSkinToneSupport: false,
                searchKey: "musicalKeyboard",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3BA],
                isSkinToneSupport: false,
                searchKey: "trumpet",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3BB],
                isSkinToneSupport: false,
                searchKey: "violin",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA95],
                isSkinToneSupport: false,
                searchKey: "banjo",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F941],
                isSkinToneSupport: false,
                searchKey: "drum",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA98],
                isSkinToneSupport: false,
                searchKey: "longDrum",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA87],
                isSkinToneSupport: false,
                searchKey: "maracas",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA88],
                isSkinToneSupport: false,
                searchKey: "flute",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4F1],
                isSkinToneSupport: false,
                searchKey: "mobilePhone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4F2],
                isSkinToneSupport: false,
                searchKey: "mobilePhoneWithArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x260E, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "telephone",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4DE],
                isSkinToneSupport: false,
                searchKey: "telephoneReceiver",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4DF],
                isSkinToneSupport: false,
                searchKey: "pager",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E0],
                isSkinToneSupport: false,
                searchKey: "faxMachine",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F50B],
                isSkinToneSupport: false,
                searchKey: "battery",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAAB],
                isSkinToneSupport: false,
                searchKey: "lowBattery",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F50C],
                isSkinToneSupport: false,
                searchKey: "electricPlug",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4BB],
                isSkinToneSupport: false,
                searchKey: "laptop",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5A5, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "desktopComputer",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5A8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "printer",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2328, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "keyboard",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5B1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "computerMouse",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5B2, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "trackball",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4BD],
                isSkinToneSupport: false,
                searchKey: "computerDisk",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4BE],
                isSkinToneSupport: false,
                searchKey: "floppyDisk",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4BF],
                isSkinToneSupport: false,
                searchKey: "opticalDisk",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C0],
                isSkinToneSupport: false,
                searchKey: "dvd",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9EE],
                isSkinToneSupport: false,
                searchKey: "abacus",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3A5],
                isSkinToneSupport: false,
                searchKey: "movieCamera",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F39E, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "filmFrames",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4FD, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "filmProjector",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3AC],
                isSkinToneSupport: false,
                searchKey: "clapperBoard",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4FA],
                isSkinToneSupport: false,
                searchKey: "television",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4F7],
                isSkinToneSupport: false,
                searchKey: "camera",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4F8],
                isSkinToneSupport: false,
                searchKey: "cameraWithFlash",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4F9],
                isSkinToneSupport: false,
                searchKey: "videoCamera",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4FC],
                isSkinToneSupport: false,
                searchKey: "videocassette",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F50D],
                isSkinToneSupport: false,
                searchKey: "magnifyingGlassTiltedLeft",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F50E],
                isSkinToneSupport: false,
                searchKey: "magnifyingGlassTiltedRight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F56F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "candle",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4A1],
                isSkinToneSupport: false,
                searchKey: "lightBulb",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F526],
                isSkinToneSupport: false,
                searchKey: "flashlight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3EE],
                isSkinToneSupport: false,
                searchKey: "redPaperLantern",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA94],
                isSkinToneSupport: false,
                searchKey: "diyaLamp",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4D4],
                isSkinToneSupport: false,
                searchKey: "notebookWithDecorativeCover",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D5],
                isSkinToneSupport: false,
                searchKey: "closedBook",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D6],
                isSkinToneSupport: false,
                searchKey: "openBook",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D7],
                isSkinToneSupport: false,
                searchKey: "greenBook",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D8],
                isSkinToneSupport: false,
                searchKey: "blueBook",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D9],
                isSkinToneSupport: false,
                searchKey: "orangeBook",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4DA],
                isSkinToneSupport: false,
                searchKey: "books",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D3],
                isSkinToneSupport: false,
                searchKey: "notebook",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D2],
                isSkinToneSupport: false,
                searchKey: "ledger",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C3],
                isSkinToneSupport: false,
                searchKey: "pageWithCurl",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4DC],
                isSkinToneSupport: false,
                searchKey: "scroll",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C4],
                isSkinToneSupport: false,
                searchKey: "pageFacingUp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4F0],
                isSkinToneSupport: false,
                searchKey: "newspaper",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5DE, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rolledUpNewspaper",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4D1],
                isSkinToneSupport: false,
                searchKey: "bookmarkTabs",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F516],
                isSkinToneSupport: false,
                searchKey: "bookmark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3F7, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "label",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4B0],
                isSkinToneSupport: false,
                searchKey: "moneyBag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA99],
                isSkinToneSupport: false,
                searchKey: "coin",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4B4],
                isSkinToneSupport: false,
                searchKey: "yenBanknote",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4B5],
                isSkinToneSupport: false,
                searchKey: "dollarBanknote",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4B6],
                isSkinToneSupport: false,
                searchKey: "euroBanknote",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4B7],
                isSkinToneSupport: false,
                searchKey: "poundBanknote",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4B8],
                isSkinToneSupport: false,
                searchKey: "moneyWithWings",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4B3],
                isSkinToneSupport: false,
                searchKey: "creditCard",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F9FE],
                isSkinToneSupport: false,
                searchKey: "receipt",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4B9],
                isSkinToneSupport: false,
                searchKey: "chartIncreasingWithYen",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2709, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "envelope",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E7],
                isSkinToneSupport: false,
                searchKey: "eMail",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E8],
                isSkinToneSupport: false,
                searchKey: "incomingEnvelope",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E9],
                isSkinToneSupport: false,
                searchKey: "envelopeWithArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E4],
                isSkinToneSupport: false,
                searchKey: "outboxTray",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E5],
                isSkinToneSupport: false,
                searchKey: "inboxTray",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4E6],
                isSkinToneSupport: false,
                searchKey: "package",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4EB],
                isSkinToneSupport: false,
                searchKey: "closedMailboxWithRaisedFlag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4EA],
                isSkinToneSupport: false,
                searchKey: "closedMailboxWithLoweredFlag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4EC],
                isSkinToneSupport: false,
                searchKey: "openMailboxWithRaisedFlag",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4ED],
                isSkinToneSupport: false,
                searchKey: "openMailboxWithLoweredFlag",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4EE],
                isSkinToneSupport: false,
                searchKey: "postbox",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5F3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "ballotBoxWithBallot",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x270F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "pencil",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2712, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "blackNib",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F58B, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "fountainPen",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F58A, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "pen",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F58C, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "paintbrush",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F58D, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "crayon",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4DD],
                isSkinToneSupport: false,
                searchKey: "memo",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4BC],
                isSkinToneSupport: false,
                searchKey: "briefcase",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C1],
                isSkinToneSupport: false,
                searchKey: "fileFolder",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C2],
                isSkinToneSupport: false,
                searchKey: "openFileFolder",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5C2, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cardIndexDividers",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4C5],
                isSkinToneSupport: false,
                searchKey: "calendar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C6],
                isSkinToneSupport: false,
                searchKey: "tearOffCalendar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5D2, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "spiralNotepad",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5D3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "spiralCalendar",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4C7],
                isSkinToneSupport: false,
                searchKey: "cardIndex",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C8],
                isSkinToneSupport: false,
                searchKey: "chartIncreasing",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4C9],
                isSkinToneSupport: false,
                searchKey: "chartDecreasing",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4CA],
                isSkinToneSupport: false,
                searchKey: "barChart",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4CB],
                isSkinToneSupport: false,
                searchKey: "clipboard",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4CC],
                isSkinToneSupport: false,
                searchKey: "pushpin",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4CD],
                isSkinToneSupport: false,
                searchKey: "roundPushpin",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4CE],
                isSkinToneSupport: false,
                searchKey: "paperclip",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F587, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "linkedPaperclips",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F4CF],
                isSkinToneSupport: false,
                searchKey: "straightRuler",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4D0],
                isSkinToneSupport: false,
                searchKey: "triangularRuler",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2702, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "scissors",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5C3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "cardFileBox",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5C4, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "fileCabinet",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5D1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "wastebasket",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F512],
                isSkinToneSupport: false,
                searchKey: "locked",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F513],
                isSkinToneSupport: false,
                searchKey: "unlocked",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F50F],
                isSkinToneSupport: false,
                searchKey: "lockedWithPen",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F510],
                isSkinToneSupport: false,
                searchKey: "lockedWithKey",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F511],
                isSkinToneSupport: false,
                searchKey: "key",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F5DD, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "oldKey",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F528],
                isSkinToneSupport: false,
                searchKey: "hammer",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA93],
                isSkinToneSupport: false,
                searchKey: "axe",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x26CF, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "pick",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2692, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "hammerAndPick",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6E0, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "hammerAndWrench",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F5E1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "dagger",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2694, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "crossedSwords",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4A3],
                isSkinToneSupport: false,
                searchKey: "bomb",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA83],
                isSkinToneSupport: false,
                searchKey: "boomerang",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F9],
                isSkinToneSupport: false,
                searchKey: "bowAndArrow",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6E1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "shield",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1FA9A],
                isSkinToneSupport: false,
                searchKey: "carpentrySaw",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F527],
                isSkinToneSupport: false,
                searchKey: "wrench",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA9B],
                isSkinToneSupport: false,
                searchKey: "screwdriver",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F529],
                isSkinToneSupport: false,
                searchKey: "nutAndBolt",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2699, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "gear",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5DC, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "clamp",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2696, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "balanceScale",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9AF],
                isSkinToneSupport: false,
                searchKey: "whiteCane",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F517],
                isSkinToneSupport: false,
                searchKey: "link",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26D3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "chains",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1FA9D],
                isSkinToneSupport: false,
                searchKey: "hook",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F0],
                isSkinToneSupport: false,
                searchKey: "toolbox",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F2],
                isSkinToneSupport: false,
                searchKey: "magnet",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA9C],
                isSkinToneSupport: false,
                searchKey: "ladder",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x2697, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "alembic",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9EA],
                isSkinToneSupport: false,
                searchKey: "testTube",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9EB],
                isSkinToneSupport: false,
                searchKey: "petriDish",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9EC],
                isSkinToneSupport: false,
                searchKey: "dna",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F52C],
                isSkinToneSupport: false,
                searchKey: "microscope",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F52D],
                isSkinToneSupport: false,
                searchKey: "telescope",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4E1],
                isSkinToneSupport: false,
                searchKey: "satelliteAntenna",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F489],
                isSkinToneSupport: false,
                searchKey: "syringe",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA78],
                isSkinToneSupport: false,
                searchKey: "dropOfBlood",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F48A],
                isSkinToneSupport: false,
                searchKey: "pill",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FA79],
                isSkinToneSupport: false,
                searchKey: "adhesiveBandage",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA7C],
                isSkinToneSupport: false,
                searchKey: "crutch",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA7A],
                isSkinToneSupport: false,
                searchKey: "stethoscope",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA7B],
                isSkinToneSupport: false,
                searchKey: "xRay",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6AA],
                isSkinToneSupport: false,
                searchKey: "door",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6D7],
                isSkinToneSupport: false,
                searchKey: "elevator",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA9E],
                isSkinToneSupport: false,
                searchKey: "mirror",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA9F],
                isSkinToneSupport: false,
                searchKey: "window",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6CF, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "bed",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F6CB, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "couchAndLamp",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1FA91],
                isSkinToneSupport: false,
                searchKey: "chair",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6BD],
                isSkinToneSupport: false,
                searchKey: "toilet",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAA0],
                isSkinToneSupport: false,
                searchKey: "plunger",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6BF],
                isSkinToneSupport: false,
                searchKey: "shower",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6C1],
                isSkinToneSupport: false,
                searchKey: "bathtub",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA4],
                isSkinToneSupport: false,
                searchKey: "mouseTrap",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FA92],
                isSkinToneSupport: false,
                searchKey: "razor",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F4],
                isSkinToneSupport: false,
                searchKey: "lotionBottle",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F7],
                isSkinToneSupport: false,
                searchKey: "safetyPin",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9F9],
                isSkinToneSupport: false,
                searchKey: "broom",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9FA],
                isSkinToneSupport: false,
                searchKey: "basket",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9FB],
                isSkinToneSupport: false,
                searchKey: "rollOfPaper",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA3],
                isSkinToneSupport: false,
                searchKey: "bucket",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9FC],
                isSkinToneSupport: false,
                searchKey: "soap",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAE7],
                isSkinToneSupport: false,
                searchKey: "bubbles",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA5],
                isSkinToneSupport: false,
                searchKey: "toothbrush",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9FD],
                isSkinToneSupport: false,
                searchKey: "sponge",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9EF],
                isSkinToneSupport: false,
                searchKey: "fireExtinguisher",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6D2],
                isSkinToneSupport: false,
                searchKey: "shoppingCart",
                version: 3.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6AC],
                isSkinToneSupport: false,
                searchKey: "cigarette",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26B0, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "coffin",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAA6],
                isSkinToneSupport: false,
                searchKey: "headstone",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x26B1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "funeralUrn",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F9FF],
                isSkinToneSupport: false,
                searchKey: "nazarAmulet",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAAC],
                isSkinToneSupport: false,
                searchKey: "hamsa",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x1F5FF],
                isSkinToneSupport: false,
                searchKey: "moai",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAA7],
                isSkinToneSupport: false,
                searchKey: "placard",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1FAAA],
                isSkinToneSupport: false,
                searchKey: "identificationCard",
                version: 14.0
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
    
    private let symbolEmojis: MCEmojiCategory = .init(
        type: .symbols,
        categoryName: MCEmojiCategoryType.symbols.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F3E7],
                isSkinToneSupport: false,
                searchKey: "aTMSign",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6AE],
                isSkinToneSupport: false,
                searchKey: "litterInBinSign",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B0],
                isSkinToneSupport: false,
                searchKey: "potableWater",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x267F],
                isSkinToneSupport: false,
                searchKey: "wheelchairSymbol",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6B9],
                isSkinToneSupport: false,
                searchKey: "menSRoom",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6BA],
                isSkinToneSupport: false,
                searchKey: "womenSRoom",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6BB],
                isSkinToneSupport: false,
                searchKey: "restroom",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6BC],
                isSkinToneSupport: false,
                searchKey: "babySymbol",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6BE],
                isSkinToneSupport: false,
                searchKey: "waterCloset",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6C2],
                isSkinToneSupport: false,
                searchKey: "passportControl",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6C3],
                isSkinToneSupport: false,
                searchKey: "customs",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6C4],
                isSkinToneSupport: false,
                searchKey: "baggageClaim",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6C5],
                isSkinToneSupport: false,
                searchKey: "leftLuggage",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x26A0, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "warning",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6B8],
                isSkinToneSupport: false,
                searchKey: "childrenCrossing",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x26D4],
                isSkinToneSupport: false,
                searchKey: "noEntry",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6AB],
                isSkinToneSupport: false,
                searchKey: "prohibited",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6B3],
                isSkinToneSupport: false,
                searchKey: "noBicycles",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6AD],
                isSkinToneSupport: false,
                searchKey: "noSmoking",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6AF],
                isSkinToneSupport: false,
                searchKey: "noLittering",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B1],
                isSkinToneSupport: false,
                searchKey: "nonPotableWater",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F6B7],
                isSkinToneSupport: false,
                searchKey: "noPedestrians",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4F5],
                isSkinToneSupport: false,
                searchKey: "noMobilePhones",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F51E],
                isSkinToneSupport: false,
                searchKey: "noOneUnderEighteen",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2622, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "radioactive",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x2623, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "biohazard",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x2B06, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "upArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2197, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "upRightArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x27A1, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rightArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2198, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "downRightArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2B07, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "downArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2199, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "downLeftArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2B05, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "leftArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2196, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "upLeftArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2195, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "upDownArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2194, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "leftRightArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x21A9, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rightArrowCurvingLeft",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x21AA, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "leftArrowCurvingRight",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2934, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rightArrowCurvingUp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2935, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "rightArrowCurvingDown",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F503],
                isSkinToneSupport: false,
                searchKey: "clockwiseVerticalArrows",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F504],
                isSkinToneSupport: false,
                searchKey: "counterclockwiseArrowsButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F519],
                isSkinToneSupport: false,
                searchKey: "bACKArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F51A],
                isSkinToneSupport: false,
                searchKey: "eNDArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F51B],
                isSkinToneSupport: false,
                searchKey: "oNArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F51C],
                isSkinToneSupport: false,
                searchKey: "sOONArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F51D],
                isSkinToneSupport: false,
                searchKey: "tOPArrow",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6D0],
                isSkinToneSupport: false,
                searchKey: "placeOfWorship",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x269B, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "atomSymbol",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F549, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "om",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2721, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "starOfDavid",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2638, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "wheelOfDharma",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x262F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "yinYang",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x271D, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "latinCross",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x2626, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "orthodoxCross",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x262A, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "starAndCrescent",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x262E, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "peaceSymbol",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F54E],
                isSkinToneSupport: false,
                searchKey: "menorah",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F52F],
                isSkinToneSupport: false,
                searchKey: "dottedSixPointedStar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1FAAF],
                isSkinToneSupport: false,
                searchKey: "khanda",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x2648],
                isSkinToneSupport: false,
                searchKey: "aries",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2649],
                isSkinToneSupport: false,
                searchKey: "taurus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x264A],
                isSkinToneSupport: false,
                searchKey: "gemini",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x264B],
                isSkinToneSupport: false,
                searchKey: "cancer",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x264C],
                isSkinToneSupport: false,
                searchKey: "leo",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x264D],
                isSkinToneSupport: false,
                searchKey: "virgo",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x264E],
                isSkinToneSupport: false,
                searchKey: "libra",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x264F],
                isSkinToneSupport: false,
                searchKey: "scorpio",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2650],
                isSkinToneSupport: false,
                searchKey: "sagittarius",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2651],
                isSkinToneSupport: false,
                searchKey: "capricorn",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2652],
                isSkinToneSupport: false,
                searchKey: "aquarius",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2653],
                isSkinToneSupport: false,
                searchKey: "pisces",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26CE],
                isSkinToneSupport: false,
                searchKey: "ophiuchus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F500],
                isSkinToneSupport: false,
                searchKey: "shuffleTracksButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F501],
                isSkinToneSupport: false,
                searchKey: "repeatButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F502],
                isSkinToneSupport: false,
                searchKey: "repeatSingleButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x25B6, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "playButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23E9],
                isSkinToneSupport: false,
                searchKey: "fastForwardButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23ED, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "nextTrackButton",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x23EF, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "playOrPauseButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x25C0, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "reverseButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23EA],
                isSkinToneSupport: false,
                searchKey: "fastReverseButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23EE, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "lastTrackButton",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F53C],
                isSkinToneSupport: false,
                searchKey: "upwardsButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23EB],
                isSkinToneSupport: false,
                searchKey: "fastUpButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F53D],
                isSkinToneSupport: false,
                searchKey: "downwardsButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23EC],
                isSkinToneSupport: false,
                searchKey: "fastDownButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x23F8, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "pauseButton",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x23F9, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "stopButton",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x23FA, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "recordButton",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x23CF, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "ejectButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3A6],
                isSkinToneSupport: false,
                searchKey: "cinema",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F505],
                isSkinToneSupport: false,
                searchKey: "dimButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F506],
                isSkinToneSupport: false,
                searchKey: "brightButton",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4F6],
                isSkinToneSupport: false,
                searchKey: "antennaBars",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6DC],
                isSkinToneSupport: false,
                searchKey: "wireless",
                version: 15.0
            ),
            MCEmoji(
                emojiKeys: [0x1F4F3],
                isSkinToneSupport: false,
                searchKey: "vibrationMode",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4F4],
                isSkinToneSupport: false,
                searchKey: "mobilePhoneOff",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2640, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "femaleSign",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x2642, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "maleSign",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x26A7, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "transgenderSymbol",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x2716, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "multiply",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2795],
                isSkinToneSupport: false,
                searchKey: "plus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2796],
                isSkinToneSupport: false,
                searchKey: "minus",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2797],
                isSkinToneSupport: false,
                searchKey: "divide",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F7F0],
                isSkinToneSupport: false,
                searchKey: "heavyEqualsSign",
                version: 14.0
            ),
            MCEmoji(
                emojiKeys: [0x267E, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "infinity",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x203C, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "doubleExclamationMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2049, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "exclamationQuestionMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2753],
                isSkinToneSupport: false,
                searchKey: "redQuestionMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2754],
                isSkinToneSupport: false,
                searchKey: "whiteQuestionMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2755],
                isSkinToneSupport: false,
                searchKey: "whiteExclamationMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2757],
                isSkinToneSupport: false,
                searchKey: "redExclamationMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x3030, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "wavyDash",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4B1],
                isSkinToneSupport: false,
                searchKey: "currencyExchange",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4B2],
                isSkinToneSupport: false,
                searchKey: "heavyDollarSign",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2695, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "medicalSymbol",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x267B, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "recyclingSymbol",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x269C, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "fleurDeLis",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F531],
                isSkinToneSupport: false,
                searchKey: "tridentEmblem",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4DB],
                isSkinToneSupport: false,
                searchKey: "nameBadge",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F530],
                isSkinToneSupport: false,
                searchKey: "japaneseSymbolForBeginner",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2B55],
                isSkinToneSupport: false,
                searchKey: "hollowRedCircle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2705],
                isSkinToneSupport: false,
                searchKey: "checkMarkButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2611, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "checkBoxWithCheck",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2714, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "checkMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x274C],
                isSkinToneSupport: false,
                searchKey: "crossMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x274E],
                isSkinToneSupport: false,
                searchKey: "crossMarkButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x27B0],
                isSkinToneSupport: false,
                searchKey: "curlyLoop",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x27BF],
                isSkinToneSupport: false,
                searchKey: "doubleCurlyLoop",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x303D, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "partAlternationMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2733, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "eightSpokedAsterisk",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2734, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "eightPointedStar",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2747, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "sparkle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x00A9, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "copyright",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x00AE, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "registered",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2122, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "tradeMark",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0023, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x002A, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x0030, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap0",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0031, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap1",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0032, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap2",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0033, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap3",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0034, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap4",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0035, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap5",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0036, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap6",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0037, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap7",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0038, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap8",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x0039, 0xFE0F, 0x20E3],
                isSkinToneSupport: false,
                searchKey: "keycap9",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F51F],
                isSkinToneSupport: false,
                searchKey: "keycap10",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F520],
                isSkinToneSupport: false,
                searchKey: "inputLatinUppercase",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F521],
                isSkinToneSupport: false,
                searchKey: "inputLatinLowercase",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F522],
                isSkinToneSupport: false,
                searchKey: "inputNumbers",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F523],
                isSkinToneSupport: false,
                searchKey: "inputSymbols",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F524],
                isSkinToneSupport: false,
                searchKey: "inputLatinLetters",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F170, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "aButtonBloodType",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F18E],
                isSkinToneSupport: false,
                searchKey: "aBButtonBloodType",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F171, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "bButtonBloodType",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F191],
                isSkinToneSupport: false,
                searchKey: "cLButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F192],
                isSkinToneSupport: false,
                searchKey: "cOOLButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F193],
                isSkinToneSupport: false,
                searchKey: "fREEButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2139, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "information",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F194],
                isSkinToneSupport: false,
                searchKey: "iDButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x24C2, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "circledM",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F195],
                isSkinToneSupport: false,
                searchKey: "nEWButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F196],
                isSkinToneSupport: false,
                searchKey: "nGButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F17E, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "oButtonBloodType",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F197],
                isSkinToneSupport: false,
                searchKey: "oKButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F17F, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "pButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F198],
                isSkinToneSupport: false,
                searchKey: "sOSButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F199],
                isSkinToneSupport: false,
                searchKey: "uPButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F19A],
                isSkinToneSupport: false,
                searchKey: "vSButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F201],
                isSkinToneSupport: false,
                searchKey: "japaneseHereButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F202, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "japaneseServiceChargeButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F237, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "japaneseMonthlyAmountButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F236],
                isSkinToneSupport: false,
                searchKey: "japaneseNotFreeOfChargeButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F22F],
                isSkinToneSupport: false,
                searchKey: "japaneseReservedButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F250],
                isSkinToneSupport: false,
                searchKey: "japaneseBargainButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F239],
                isSkinToneSupport: false,
                searchKey: "japaneseDiscountButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F21A],
                isSkinToneSupport: false,
                searchKey: "japaneseFreeOfChargeButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F232],
                isSkinToneSupport: false,
                searchKey: "japaneseProhibitedButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F251],
                isSkinToneSupport: false,
                searchKey: "japaneseAcceptableButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F238],
                isSkinToneSupport: false,
                searchKey: "japaneseApplicationButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F234],
                isSkinToneSupport: false,
                searchKey: "japanesePassingGradeButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F233],
                isSkinToneSupport: false,
                searchKey: "japaneseVacancyButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x3297, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "japaneseCongratulationsButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x3299, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "japaneseSecretButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F23A],
                isSkinToneSupport: false,
                searchKey: "japaneseOpenForBusinessButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F235],
                isSkinToneSupport: false,
                searchKey: "japaneseNoVacancyButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F534],
                isSkinToneSupport: false,
                searchKey: "redCircle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F7E0],
                isSkinToneSupport: false,
                searchKey: "orangeCircle",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E1],
                isSkinToneSupport: false,
                searchKey: "yellowCircle",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E2],
                isSkinToneSupport: false,
                searchKey: "greenCircle",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F535],
                isSkinToneSupport: false,
                searchKey: "blueCircle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F7E3],
                isSkinToneSupport: false,
                searchKey: "purpleCircle",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E4],
                isSkinToneSupport: false,
                searchKey: "brownCircle",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x26AB],
                isSkinToneSupport: false,
                searchKey: "blackCircle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x26AA],
                isSkinToneSupport: false,
                searchKey: "whiteCircle",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F7E5],
                isSkinToneSupport: false,
                searchKey: "redSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E7],
                isSkinToneSupport: false,
                searchKey: "orangeSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E8],
                isSkinToneSupport: false,
                searchKey: "yellowSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E9],
                isSkinToneSupport: false,
                searchKey: "greenSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7E6],
                isSkinToneSupport: false,
                searchKey: "blueSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7EA],
                isSkinToneSupport: false,
                searchKey: "purpleSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x1F7EB],
                isSkinToneSupport: false,
                searchKey: "brownSquare",
                version: 12.0
            ),
            MCEmoji(
                emojiKeys: [0x2B1B],
                isSkinToneSupport: false,
                searchKey: "blackLargeSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x2B1C],
                isSkinToneSupport: false,
                searchKey: "whiteLargeSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x25FC, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "blackMediumSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x25FB, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "whiteMediumSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x25FE],
                isSkinToneSupport: false,
                searchKey: "blackMediumSmallSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x25FD],
                isSkinToneSupport: false,
                searchKey: "whiteMediumSmallSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x25AA, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "blackSmallSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x25AB, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "whiteSmallSquare",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F536],
                isSkinToneSupport: false,
                searchKey: "largeOrangeDiamond",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F537],
                isSkinToneSupport: false,
                searchKey: "largeBlueDiamond",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F538],
                isSkinToneSupport: false,
                searchKey: "smallOrangeDiamond",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F539],
                isSkinToneSupport: false,
                searchKey: "smallBlueDiamond",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F53A],
                isSkinToneSupport: false,
                searchKey: "redTrianglePointedUp",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F53B],
                isSkinToneSupport: false,
                searchKey: "redTrianglePointedDown",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F4A0],
                isSkinToneSupport: false,
                searchKey: "diamondWithADot",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F518],
                isSkinToneSupport: false,
                searchKey: "radioButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F533],
                isSkinToneSupport: false,
                searchKey: "whiteSquareButton",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F532],
                isSkinToneSupport: false,
                searchKey: "blackSquareButton",
                version: 0.6
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
    
    private let flagEmojis: MCEmojiCategory = .init(
        type: .flags,
        categoryName: MCEmojiCategoryType.flags.emojiCategoryTitle,
        emojis: [
            MCEmoji(
                emojiKeys: [0x1F3C1],
                isSkinToneSupport: false,
                searchKey: "chequeredFlag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F6A9],
                isSkinToneSupport: false,
                searchKey: "triangularFlag",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F38C],
                isSkinToneSupport: false,
                searchKey: "crossedFlags",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F3F4],
                isSkinToneSupport: false,
                searchKey: "blackFlag",
                version: 1.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F3, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "whiteFlag",
                version: 0.7
            ),
            MCEmoji(
                emojiKeys: [0x1F3F3, 0xFE0F, 0x200D, 0x1F308],
                isSkinToneSupport: false,
                searchKey: "rainbowFlag",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F3, 0xFE0F, 0x200D, 0x26A7, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "transgenderFlag",
                version: 13.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F4, 0x200D, 0x2620, 0xFE0F],
                isSkinToneSupport: false,
                searchKey: "pirateFlag",
                version: 11.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagAscensionIsland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagAndorra",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagUnitedArabEmirates",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagAfghanistan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagAntiguaBarbuda",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagAnguilla",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagAlbania",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagArmenia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagAngola",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F6],
                isSkinToneSupport: false,
                searchKey: "flagAntarctica",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagArgentina",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagAmericanSamoa",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagAustria",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagAustralia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagAruba",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1FD],
                isSkinToneSupport: false,
                searchKey: "flagÅlandIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E6, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagAzerbaijan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagBosniaHerzegovina",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1E7],
                isSkinToneSupport: false,
                searchKey: "flagBarbados",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagBangladesh",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagBelgium",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagBurkinaFaso",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagBulgaria",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagBahrain",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagBurundi",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1EF],
                isSkinToneSupport: false,
                searchKey: "flagBenin",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagStBarthélemy",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagBermuda",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagBrunei",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagBolivia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F6],
                isSkinToneSupport: false,
                searchKey: "flagCaribbeanNetherlands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagBrazil",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagBahamas",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagBhutan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1FB],
                isSkinToneSupport: false,
                searchKey: "flagBouvetIsland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagBotswana",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagBelarus",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E7, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagBelize",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagCanada",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagCocosKeelingIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagCongoKinshasa",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagCentralAfricanRepublic",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagCongoBrazzaville",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagSwitzerland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagCôteDIvoire",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagCookIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagChile",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagCameroon",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagChina",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagColombia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F5],
                isSkinToneSupport: false,
                searchKey: "flagClippertonIsland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagCostaRica",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagCuba",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1FB],
                isSkinToneSupport: false,
                searchKey: "flagCapeVerde",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagCuraçao",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1FD],
                isSkinToneSupport: false,
                searchKey: "flagChristmasIsland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagCyprus",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E8, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagCzechia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagGermany",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagDiegoGarcia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1EF],
                isSkinToneSupport: false,
                searchKey: "flagDjibouti",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagDenmark",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagDominica",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagDominicanRepublic",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1E9, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagAlgeria",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagCeutaMelilla",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagEcuador",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagEstonia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagEgypt",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagWesternSahara",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagEritrea",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagSpain",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagEthiopia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EA, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagEuropeanUnion",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EB, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagFinland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EB, 0x1F1EF],
                isSkinToneSupport: false,
                searchKey: "flagFiji",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EB, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagFalklandIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EB, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagMicronesia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EB, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagFaroeIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EB, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagFrance",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagGabon",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1E7],
                isSkinToneSupport: false,
                searchKey: "flagUnitedKingdom",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagGrenada",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagGeorgia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagFrenchGuiana",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagGuernsey",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagGhana",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagGibraltar",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagGreenland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagGambia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagGuinea",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F5],
                isSkinToneSupport: false,
                searchKey: "flagGuadeloupe",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F6],
                isSkinToneSupport: false,
                searchKey: "flagEquatorialGuinea",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagGreece",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagSouthGeorgiaSouthSandwichIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagGuatemala",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagGuam",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagGuineaBissau",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EC, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagGuyana",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1ED, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagHongKongSARChina",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1ED, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagHeardMcDonaldIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1ED, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagHonduras",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1ED, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagCroatia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1ED, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagHaiti",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1ED, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagHungary",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagCanaryIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagIndonesia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagIreland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagIsrael",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagIsleOfMan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagIndia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagBritishIndianOceanTerritory",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F6],
                isSkinToneSupport: false,
                searchKey: "flagIraq",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagIran",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagIceland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EE, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagItaly",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1EF, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagJersey",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EF, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagJamaica",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EF, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagJordan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1EF, 0x1F1F5],
                isSkinToneSupport: false,
                searchKey: "flagJapan",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagKenya",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagKyrgyzstan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagCambodia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagKiribati",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagComoros",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagStKittsNevis",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1F5],
                isSkinToneSupport: false,
                searchKey: "flagNorthKorea",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagSouthKorea",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagKuwait",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagCaymanIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F0, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagKazakhstan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagLaos",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1E7],
                isSkinToneSupport: false,
                searchKey: "flagLebanon",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagStLucia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagLiechtenstein",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagSriLanka",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagLiberia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagLesotho",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagLithuania",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagLuxembourg",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1FB],
                isSkinToneSupport: false,
                searchKey: "flagLatvia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F1, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagLibya",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagMorocco",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagMonaco",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagMoldova",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagMontenegro",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagStMartin",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagMadagascar",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagMarshallIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagNorthMacedonia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagMali",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagMyanmarBurma",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagMongolia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagMacaoSARChina",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F5],
                isSkinToneSupport: false,
                searchKey: "flagNorthernMarianaIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F6],
                isSkinToneSupport: false,
                searchKey: "flagMartinique",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagMauritania",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagMontserrat",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagMalta",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagMauritius",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1FB],
                isSkinToneSupport: false,
                searchKey: "flagMaldives",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagMalawi",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1FD],
                isSkinToneSupport: false,
                searchKey: "flagMexico",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagMalaysia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F2, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagMozambique",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagNamibia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagNewCaledonia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagNiger",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagNorfolkIsland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagNigeria",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagNicaragua",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagNetherlands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagNorway",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1F5],
                isSkinToneSupport: false,
                searchKey: "flagNepal",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagNauru",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagNiue",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F3, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagNewZealand",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F4, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagOman",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagPanama",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagPeru",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagFrenchPolynesia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagPapuaNewGuinea",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagPhilippines",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagPakistan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagPoland",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagStPierreMiquelon",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagPitcairnIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagPuertoRico",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagPalestinianTerritories",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagPortugal",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagPalau",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F5, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagParaguay",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F6, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagQatar",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F7, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagRéunion",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F7, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagRomania",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F7, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagSerbia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F7, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagRussia",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1F7, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagRwanda",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagSaudiArabia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1E7],
                isSkinToneSupport: false,
                searchKey: "flagSolomonIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagSeychelles",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagSudan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagSweden",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagSingapore",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagStHelena",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagSlovenia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1EF],
                isSkinToneSupport: false,
                searchKey: "flagSvalbardJanMayen",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagSlovakia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagSierraLeone",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagSanMarino",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagSenegal",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagSomalia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagSuriname",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagSouthSudan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagSãoToméPríncipe",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1FB],
                isSkinToneSupport: false,
                searchKey: "flagElSalvador",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1FD],
                isSkinToneSupport: false,
                searchKey: "flagSintMaarten",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagSyria",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F8, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagEswatini",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagTristanDaCunha",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagTurksCaicosIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1E9],
                isSkinToneSupport: false,
                searchKey: "flagChad",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagFrenchSouthernTerritories",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagTogo",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1ED],
                isSkinToneSupport: false,
                searchKey: "flagThailand",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1EF],
                isSkinToneSupport: false,
                searchKey: "flagTajikistan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagTokelau",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F1],
                isSkinToneSupport: false,
                searchKey: "flagTimorLeste",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagTurkmenistan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagTunisia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F4],
                isSkinToneSupport: false,
                searchKey: "flagTonga",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F7],
                isSkinToneSupport: false,
                searchKey: "flagTurkey",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagTrinidadTobago",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1FB],
                isSkinToneSupport: false,
                searchKey: "flagTuvalu",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagTaiwan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1F9, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagTanzania",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagUkraine",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagUganda",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagUSOutlyingIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagUnitedNations",
                version: 4.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagUnitedStates",
                version: 0.6
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1FE],
                isSkinToneSupport: false,
                searchKey: "flagUruguay",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FA, 0x1F1FF],
                isSkinToneSupport: false,
                searchKey: "flagUzbekistan",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagVaticanCity",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1E8],
                isSkinToneSupport: false,
                searchKey: "flagStVincentGrenadines",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagVenezuela",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1EC],
                isSkinToneSupport: false,
                searchKey: "flagBritishVirginIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1EE],
                isSkinToneSupport: false,
                searchKey: "flagUSVirginIslands",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1F3],
                isSkinToneSupport: false,
                searchKey: "flagVietnam",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FB, 0x1F1FA],
                isSkinToneSupport: false,
                searchKey: "flagVanuatu",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FC, 0x1F1EB],
                isSkinToneSupport: false,
                searchKey: "flagWallisFutuna",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FC, 0x1F1F8],
                isSkinToneSupport: false,
                searchKey: "flagSamoa",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FD, 0x1F1F0],
                isSkinToneSupport: false,
                searchKey: "flagKosovo",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FE, 0x1F1EA],
                isSkinToneSupport: false,
                searchKey: "flagYemen",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FE, 0x1F1F9],
                isSkinToneSupport: false,
                searchKey: "flagMayotte",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FF, 0x1F1E6],
                isSkinToneSupport: false,
                searchKey: "flagSouthAfrica",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FF, 0x1F1F2],
                isSkinToneSupport: false,
                searchKey: "flagZambia",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F1FF, 0x1F1FC],
                isSkinToneSupport: false,
                searchKey: "flagZimbabwe",
                version: 2.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F],
                isSkinToneSupport: false,
                searchKey: "flagEngland",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F],
                isSkinToneSupport: false,
                searchKey: "flagScotland",
                version: 5.0
            ),
            MCEmoji(
                emojiKeys: [0x1F3F4, 0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F],
                isSkinToneSupport: false,
                searchKey: "flagWales",
                version: 5.0
            )
        ].filter({ $0.version <= maxCurrentAvailableEmojiVersion })
    )
    
}
