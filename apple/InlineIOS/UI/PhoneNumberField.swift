import SwiftUI

struct PhoneNumberField: View {
  @Binding var phoneNumber: String
  @Binding var selectedCountry: Country
  @State private var showingCountryPicker = false
  @State private var searchText = ""
  @FocusState private var isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme

  enum Size {
    case small
    case medium
    case large
  }

  var size: Size = .large

  init(phoneNumber: Binding<String>, country: Binding<Country>, size: Size = .large) {
    _phoneNumber = phoneNumber
    _selectedCountry = country
    self.size = size
  }

  private func buttonColor() -> Color {
    if colorScheme == .dark {
      Color(red: 0x8B / 255.0, green: 0x77 / 255.0, blue: 0xDC / 255.0)
    } else {
      Color(red: 0xA2 / 255.0, green: 0x8C / 255.0, blue: 0xF2 / 255.0)
    }
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
      case .small: 32
      case .medium: 40
      case .large: 48
    }
  }

  var cornerRadius: CGFloat {
    switch size {
      case .small: 8
      case .medium: 10
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
        HStack(spacing: 6) {
          Text(selectedCountry.flag)
            .font(.system(size: 18))
          Text(selectedCountry.dialCode)
            .foregroundColor(.primary)
            .font(font.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .sheet(isPresented: $showingCountryPicker) {
        NavigationView {
          VStack {
            // Search bar
            HStack {
              Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
              TextField("Search countries...", text: $searchText)
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top)

            // Countries list
            List(filteredCountries) { country in
              Button(action: {
                selectedCountry = country
                showingCountryPicker = false
              }) {
                HStack {
                  Text(country.flag)
                    .font(.system(size: 20))
                  Text(country.name)
                    .foregroundColor(.primary)
                  Spacer()
                  Text(country.dialCode)
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
                }
                .padding(.vertical, 2)
              }
              .buttonStyle(.plain)
            }
            .listStyle(.plain)
          }
          .navigationTitle("Select Country")
          .navigationBarTitleDisplayMode(.inline)
          .navigationBarItems(
            trailing: Button("Done") {
              showingCountryPicker = false
            }
          )
        }
        .presentationDetents([.medium, .large])
      }

      // Divider
      Rectangle()
        .fill(Color.primary.opacity(0.15))
        .frame(width: 1, height: height * 0.6)

      // Phone Number TextField
      TextField("Phone number", text: $phoneNumber)
        .font(font.monospacedDigit())
        .keyboardType(.phonePad)
        .focused($isFocused)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity)
        .onChange(of: phoneNumber) { _, newValue in
          phoneNumber = newValue.filter(\.isNumber)
        }
    }
    .frame(height: height)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(
              isFocused ? buttonColor() : Color(.systemGray4),
              lineWidth: isFocused ? 2 : 0.5
            )
        )
    )
    .animation(.easeInOut(duration: 0.2), value: isFocused)
  }
}

#Preview {
  @Previewable @State var phoneNumber = ""
  @Previewable @State var country = Country.getCurrentCountry()

  return VStack {
    PhoneNumberField(phoneNumber: $phoneNumber, country: $country)
      .padding()

    PhoneNumberField(phoneNumber: $phoneNumber, country: $country, size: .medium)
      .padding()

    PhoneNumberField(phoneNumber: $phoneNumber, country: $country, size: .small)
      .padding()
  }
}
