//
//  Main.swift
//  InlineXIOS
//
//  Created by Dena Sohrabi  on 3/11/26.
//

import SwiftUI

struct Main: View {
    var body: some View {
        VStack {
            Image(systemName: "bubble")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Welcome to Inline X")
        }
        .padding()
    }
}

#Preview {
    Main()
}
