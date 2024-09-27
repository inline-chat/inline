//
//  ContentView.swift
//  InlineIOS
//
//  Created by Dena Sohrabi on 9/26/24.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        Welcome()
    }
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "en"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ar"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "zh-CN"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "zh-TW"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "fr"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "de"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "it"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ja"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ko"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "fa"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "pl"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ru"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "es"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "tr"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "vi"))
}
