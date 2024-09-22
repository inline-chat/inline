//
//  ContentView.swift
//  InlineMac
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import SwiftUI

struct ContentView: View {
    var hideTitlebar: () -> Void = { }
    
    var body: some View {
        VStack {
            Text("Welcome to Inline.").font(.largeTitle)
        }
        .padding()
        .frame(minWidth: 0, idealWidth: 500, maxWidth: .infinity, minHeight: 0, idealHeight: 300, maxHeight: .infinity)
        .task {
            hideTitlebar()
        }
    }
}

#Preview {
    ContentView()
}
