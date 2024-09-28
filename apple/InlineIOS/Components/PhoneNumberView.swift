//
//  PhoneNumberView.swift
//  Inline
//
//  Created by Dena Sohrabi on 9/27/24.
//

import SwiftUI

struct PhoneNumberView: View {
    @State private var phoneNumber = ""

    var body: some View {
        VStack {
            Text("Enter your phone number")
                .font(Font.custom("Red Hat Display", size: 28))
                .fontWeight(.medium)
//            TextField("Phone Number", text: $phoneNumber)
//                .textFieldStyle(OutlinedTextFieldStyle())
//                .keyboardType(.phonePad)
//                .padding()
        }
    }
}

#Preview {
    PhoneNumberView()
}

#Preview {
    PhoneNumberView()
        .environment(\.locale, .init(identifier: "zh-CN"))
}

#Preview {
    PhoneNumberView()
        .environment(\.locale, .init(identifier: "zh-TW"))
}
