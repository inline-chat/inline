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

/// The main model that is used to configure the main collection.
struct MCEmojiCategory {
    var type: MCEmojiCategoryType
    var categoryName: String
    var emojis: [MCEmoji]
}

/// This enumeration shows a list of categories that are contained in the main collection.
enum MCEmojiCategoryType: Int, CaseIterable {
    case frequentlyUsed
    case people
    case nature
    case foodAndDrink
    case activity
    case travelAndPlaces
    case objects
    case symbols
    case flags
    
    /// A constant key for accessing name localization resources for each category.
    var localizeKey: String {
        switch self {
        case .frequentlyUsed:
            return "frequentlyUsed"
        case .people:
            return "emotionsAndPeople"
        case .nature:
            return "animalsAndNature"
        case .foodAndDrink:
            return "foodAndDrinks"
        case .activity:
            return "activities"
        case .travelAndPlaces:
            return "travellingAndPlaces"
        case .objects:
            return "items"
        case .symbols:
            return "symbols"
        case .flags:
            return "flags"
        }
    }
}
