import SwiftUI

struct PhoneNumberField: View {
  @Binding var phoneNumber: String
  @Binding var selectedCountry: Country
  @State private var showingCountryPicker = false
  @State private var searchText = ""
  @FocusState.Binding var isFocused: Bool
  @ScaledMetric(relativeTo: .body) private var onboardingHeight = OnboardingFormMetrics.controlHeight

  enum Size {
    case small
    case medium
    case large
  }

  var size: Size = .large

  init(
    phoneNumber: Binding<String>,
    country: Binding<Country>,
    focus: FocusState<Bool>.Binding,
    size: Size = .large
  ) {
    _phoneNumber = phoneNumber
    _selectedCountry = country
    _isFocused = focus
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
      case .small: 32
      case .medium: 40
      case .large: onboardingHeight
    }
  }

  var cornerRadius: CGFloat {
    switch size {
      case .small: 8
      case .medium: 10
      case .large: height / 2
    }
  }

  var font: Font {
    switch size {
      case .small: .body
      case .medium: .system(size: 16, weight: .regular)
      case .large: .onboardingIOSBody
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      // Country Code Button
      Button(action: {
        isFocused = false
        showingCountryPicker = true
      }) {
        HStack(spacing: 6) {
          Text(selectedCountry.flag)
            .font(.system(size: 18))
          Text(selectedCountry.dialCode)
            .foregroundColor(.primary)
            .font(font.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
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
        .textFieldStyle(.plain)
        .font(font.monospacedDigit())
        .keyboardType(.phonePad)
        .focused($isFocused)
        .padding(.leading, 12)
        .padding(.trailing, size == .large ? 20 : 0)
        .frame(maxWidth: .infinity)
        .onChange(of: phoneNumber) { _, newValue in
          phoneNumber = newValue.filter(\.isNumber)
        }
    }
    .frame(height: height)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(.ultraThinMaterial)
        .overlay {
          if size != .large {
            RoundedRectangle(cornerRadius: cornerRadius)
              .stroke(Color.onboardingSystemGray4, lineWidth: 0.5)
          }
        }
    )
  }
}

#Preview {
  @Previewable @State var phoneNumber = ""
  @Previewable @State var country = Country.getCurrentCountry()
  @Previewable @FocusState var largeFieldFocused: Bool
  @Previewable @FocusState var mediumFieldFocused: Bool
  @Previewable @FocusState var smallFieldFocused: Bool

  return VStack {
    PhoneNumberField(phoneNumber: $phoneNumber, country: $country, focus: $largeFieldFocused)
      .padding()

    PhoneNumberField(phoneNumber: $phoneNumber, country: $country, focus: $mediumFieldFocused, size: .medium)
      .padding()

    PhoneNumberField(phoneNumber: $phoneNumber, country: $country, focus: $smallFieldFocused, size: .small)
      .padding()
  }
}
