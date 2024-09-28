//
//  AuthMethodView.swift
//  Inline
//
//  Created by Dena Sohrabi on 9/27/24.
//

import SwiftUI

struct AuthMethodView: View {
    var body: some View {
        VStack {
            HStack {
                Image(systemName: "apple.logo")
                    .font(.title)
                Image(systemName: "phone.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)
                Image("goggle")
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            .padding(.bottom, 4)
            Text("Choose your login method:")
                .font(Font.custom("Red Hat Display", size: 22))
                .fontWeight(.medium)
                .padding(.bottom)
            Button("Continue with Email") {}
                .buttonStyle(GlassyButtonStyle())
            Button("Continue with Google") {}
                .buttonStyle(GlassyButtonStyle())
            Button("Continue with Phone") {}
                .buttonStyle(GlassyButtonStyle())
            Button("Continue with Apple") {}
                .buttonStyle(GlassyButtonStyle())
        }
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    AuthMethodView()
}
