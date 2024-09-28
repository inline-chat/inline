//
//  Welcome.swift
//  Inline
//
//  Created by Dena Sohrabi on 9/27/24.
//

import SwiftUI

struct Welcome: View {
    @EnvironmentObject var nav: Navigation
    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Text("Welcome to")
                .font(Font.custom("Red Hat Display", size: 35))
                .fontWeight(.bold)
                .opacity(0.6)
            HStack {
                Image("inlineIcon")
                    .resizable()
                    .frame(width: 100, height: 100)
                    .padding(.leading, -8)
                Text("inline")
                    .font(Font.custom("Red Hat Display", size: 60))
                    .fontWeight(.bold)
            }
        }
        .padding()
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button {
                nav.push(.email)
            } label: {
                HStack {
                    Text("Continue")
                        .padding(.trailing, 6)
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
            }
            .buttonStyle(GlassyButtonStyle())
        }
    }
}

#Preview {
    Welcome()
        .environmentObject(Navigation())
}
