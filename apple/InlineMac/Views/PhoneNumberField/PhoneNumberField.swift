import SwiftUI

struct PhoneNumberField: View {
  @Binding var phoneNumber: String
  @Binding var selectedCountry: Country
  @State private var showingCountryPicker = false
  @State private var searchText = ""
  @FocusState private var isFocused: Bool

  var size: GrayTextField.Size = .large

  init(phoneNumber: Binding<String>, country: Binding<Country>, size: GrayTextField.Size = .large) {
    _phoneNumber = phoneNumber
    _selectedCountry = country
    self.size = size
  }

  var filteredCountries: [Country] {
    if searchText.isEmpty {
      return Country.allCountries
    }
    return Country.allCountries.filter { country in
      country.name.localizedCaseInsensitiveContains(searchText) ||
        country.dialCode.localizedCaseInsensitiveContains(searchText)
    }
  }

  var height: CGFloat {
    switch size {
      case .small: 28
      case .medium: 32
      case .large: 36
    }
  }

  var cornerRadius: CGFloat {
    switch size {
      case .small: 10
      case .medium: 12
      case .large: 12
    }
  }

  var font: Font {
    switch size {
      case .small: .body
      case .medium: .system(size: 16, weight: .regular)
      case .large: .system(size: 17, weight: .regular)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      // Country Code Button
      Button(action: { showingCountryPicker.toggle() }) {
        HStack(spacing: 4) {
          Text(selectedCountry.flag)
          Text(selectedCountry.dialCode)
            .foregroundColor(.primary)
        }
        .font(font.monospacedDigit())
        .padding(.trailing, 10)
        .padding(.leading, 10)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showingCountryPicker) {
        VStack {
          TextField("Search countries...", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding()

          List(filteredCountries) { country in
            Button(action: {
              selectedCountry = country
              showingCountryPicker = false
            }) {
              HStack {
                Text(country.flag)
                Text(country.name)
                Spacer()
                Text(country.dialCode)
                  .foregroundColor(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
          .listStyle(.inset)
          .background(.clear)
          .scrollContentBackground(.hidden)
          .frame(width: 300, height: 300)
        }
      }

      // Divider
      Rectangle()
        .fill(Color.primary.opacity(0.1))
        .frame(width: 1, height: height * 0.6)

      // Phone Number TextField
      TextField("Phone number", text: $phoneNumber)
        .textFieldStyle(.plain)
        .font(font.monospacedDigit())
        .tracking(1)
        .focused($isFocused)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity)
        .onChange(of: phoneNumber) { newValue in
          phoneNumber = newValue.filter(\.isNumber)
        }
    }
    .frame(height: height)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius)
        .foregroundStyle(.primary.opacity(isFocused ? 0.1 : 0.06))
        .animation(.snappy, value: isFocused)
    )
  }
}

@available(macOS 14.0, *)
#Preview {
  @Previewable @State var phoneNumber = ""
  @Previewable @State var country = Country.getCurrentCountry()

  return PhoneNumberField(phoneNumber: $phoneNumber, country: $country)
    .padding()
}
