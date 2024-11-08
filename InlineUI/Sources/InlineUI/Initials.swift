import SwiftUI

public struct InitialsCircle: View {
    let firstName: String
    let lastName: String?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    
    private enum ColorPalette {
        // Color groups organized by hue for better variety
        static let colors: [Color] = [
            // Blues
            .init(hex: "2196F3"), // Blue
            .init(hex: "1976D2"), // Dark Blue
            .init(hex: "03A9F4"), // Light Blue
            .init(hex: "039BE5"), // Ocean Blue
            .init(hex: "0288D1"), // Deep Blue
            
            // Purples
            .init(hex: "9C27B0"), // Purple
            .init(hex: "673AB7"), // Deep Purple
            .init(hex: "7E57C2"), // Medium Purple
            .init(hex: "5E35B1"), // Rich Purple
            .init(hex: "BA68C8"), // Light Purple
            
            // Reds
            .init(hex: "F44336"), // Red
            .init(hex: "E91E63"), // Pink
            .init(hex: "D81B60"), // Deep Pink
            .init(hex: "C2185B"), // Dark Pink
            .init(hex: "FF5252"), // Bright Red
            
            // Oranges
            .init(hex: "FF9800"), // Orange
            .init(hex: "FF5722"), // Deep Orange
            .init(hex: "F4511E"), // Burnt Orange
            .init(hex: "FB8C00"), // Medium Orange
            .init(hex: "FF7043"), // Light Orange
            
            // Greens
            .init(hex: "4CAF50"), // Green
            .init(hex: "009688"), // Teal
            .init(hex: "00897B"), // Dark Teal
            .init(hex: "43A047"), // Medium Green
            .init(hex: "66BB6A"), // Light Green
            
            // Warm Colors
            .init(hex: "FFC107"), // Amber
            .init(hex: "FF9800"), // Orange
            .init(hex: "FFA726"), // Light Orange
            .init(hex: "FFB300"), // Medium Amber
            .init(hex: "FFD54F"), // Light Amber
            
            // Cool Colors
            .init(hex: "00BCD4"), // Cyan
            .init(hex: "00ACC1"), // Dark Cyan
            .init(hex: "26C6DA"), // Light Cyan
            .init(hex: "00B0FF"), // Light Blue
            .init(hex: "0091EA"), // Deep Light Blue
            
            // Additional Colors
            .init(hex: "795548"), // Brown
            .init(hex: "607D8B"), // Blue Grey
            .init(hex: "546E7A"), // Dark Blue Grey
            .init(hex: "78909C"), // Medium Blue Grey
            .init(hex: "8D6E63") // Light Brown
        ]
        
        static subscript(index: Int) -> Color {
            colors[index % colors.count]
        }
        
        static func color(for name: String) -> Color {
            let hash = abs(name.hashValue)
            return colors[hash % colors.count]
        }
    }
    
    private var initials: String {
        [firstName, lastName]
            .compactMap(\.?.first)
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
    }
    
    private var backgroundColor: Color {
        let hash = abs(firstName.hashValue &+ (lastName?.hashValue ?? 0))
        let baseColor = ColorPalette[hash % ColorPalette.colors.count]
        return colorScheme == .dark ? baseColor.opacity(0.8) : baseColor
    }
    
    public init(firstName: String, lastName: String? = nil, size: CGFloat = 32) {
        self.firstName = firstName
        self.lastName = lastName
        self.size = size
    }
    
    public var body: some View {
        Circle()
            .fill(backgroundColor)
//            .overlay(
//                Circle()
//                    .strokeBorder(borderColor, lineWidth: size * 0.03)
//            )
            .overlay(
                Text(initials)
                    .foregroundColor(.white)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            )
            .frame(width: size, height: size)
            .drawingGroup()
    }
}

// Color extension for hex initialization
private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview("InitialsCircle Grid") {
    ScrollView {
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 20) {
            Group {
                // Original names
                InitialsCircle(firstName: "John", lastName: "Doe", size: 60)
                InitialsCircle(firstName: "Alice", lastName: "Smith", size: 60)
                InitialsCircle(firstName: "Bob", lastName: "Johnson", size: 60)
                InitialsCircle(firstName: "Emma", lastName: "Davis", size: 60)
                InitialsCircle(firstName: "Michael", lastName: "Brown", size: 60)
                InitialsCircle(firstName: "Sarah", lastName: "Wilson", size: 60)
                InitialsCircle(firstName: "David", lastName: "Miller", size: 60)
                InitialsCircle(firstName: "Lisa", lastName: "Anderson", size: 60)
                InitialsCircle(firstName: "James", lastName: "Taylor", size: 60)
                InitialsCircle(firstName: "Emily", lastName: "Thomas", size: 60)
                InitialsCircle(firstName: "William", lastName: "Moore", size: 60)
                InitialsCircle(firstName: "Olivia", lastName: "Jackson", size: 60)
                
                // Tech Industry Names
                InitialsCircle(firstName: "Sam", lastName: "Altman", size: 60)
                InitialsCircle(firstName: "Elon", lastName: "Musk", size: 60)
                InitialsCircle(firstName: "Tim", lastName: "Cook", size: 60)
                InitialsCircle(firstName: "Sundar", lastName: "Pichai", size: 60)
                
                // International Names
                InitialsCircle(firstName: "Dena", lastName: "Sohrabi", size: 60)
                InitialsCircle(firstName: "Mo", lastName: "Rajabi", size: 60)
                InitialsCircle(firstName: "Dina", lastName: "Peo", size: 60)
                InitialsCircle(firstName: "Yuki", lastName: "Tanaka", size: 60)
                
                // Additional Diverse Names
                InitialsCircle(firstName: "Carlos", lastName: "Rodriguez", size: 60)
                InitialsCircle(firstName: "Priya", lastName: "Patel", size: 60)
                InitialsCircle(firstName: "Wei", lastName: "Chen", size: 60)
                InitialsCircle(firstName: "Sofia", lastName: "Martinez", size: 60)
                
                // More International Names
                InitialsCircle(firstName: "Ahmed", lastName: "Hassan", size: 60)
                InitialsCircle(firstName: "Maria", lastName: "Silva", size: 60)
                InitialsCircle(firstName: "Lars", lastName: "Nielsen", size: 60)
                InitialsCircle(firstName: "Anna", lastName: "Kowalski", size: 60)
                
                // Additional Names
                InitialsCircle(firstName: "Zara", lastName: "Khan", size: 60)
                InitialsCircle(firstName: "Leo", lastName: "Wong", size: 60)
                InitialsCircle(firstName: "Nina", lastName: "Ivanova", size: 60)
                InitialsCircle(firstName: "Kai", lastName: "Zhang", size: 60)
                
                // Single Letter Names
                InitialsCircle(firstName: "J", lastName: "Smith", size: 60)
                InitialsCircle(firstName: "K", lastName: "Park", size: 60)
                InitialsCircle(firstName: "A", lastName: "Jones", size: 60)
                InitialsCircle(firstName: "Z", lastName: "Wang", size: 60)
                
                // Names with Special Characters
                InitialsCircle(firstName: "José", lastName: "García", size: 60)
                InitialsCircle(firstName: "François", lastName: "Dubois", size: 60)
                InitialsCircle(firstName: "Søren", lastName: "Jensen", size: 60)
                InitialsCircle(firstName: "Björn", lastName: "Larsson", size: 60)
            }
            .frame(height: 60)
        }
        .padding()
    }
}
