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
        ZStack {
            Image("content-bg")
                .resizable()
                .ignoresSafeArea(.all)
            VStack(alignment: .leading, spacing: 0) {
                Image("inlineIcon")
                    .resizable()
                    .frame(width: 100, height: 100)

                Spacer()
                Text("Welcome to")
                    .font(Font.custom("Red Hat Display", size: 52))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("Inline")
                    .font(Font.custom("Red Hat Display", size: 52))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        nav.push(.email)
                    } label: {
                        Text("Continue with email")
                            .padding(.trailing, 6)
                    }
                    .buttonStyle(SimpleWhiteButtonStyle())
                    .padding(.horizontal, 44)
                    Button {
                        nav.push(.email)
                    } label: {
                        Text("Continue with phone")
                            .padding(.trailing, 6)
                    }
                    .buttonStyle(SimpleWhiteButtonStyle())
                    .padding(.bottom, 18)
                    .padding(.horizontal, 44)
                }
            }
        }
    }
}

#Preview {
    Welcome()
        .environmentObject(Navigation())
}
