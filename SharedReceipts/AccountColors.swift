import SwiftUI

enum AppColors {
    static let names = ["gray", "red", "brown", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"]

    static func displayName(_ name: String) -> String {
        switch name {
        case "gray": "Gray"
        case "red": "Red"
        case "brown": "Brown"
        case "orange": "Orange"
        case "yellow": "Yellow"
        case "green": "Green"
        case "cyan": "Turquoise"
        case "blue": "Blue"
        case "purple": "Purple"
        case "pink": "Pink"
        default: name.capitalized
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "brown": .brown
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "cyan": .cyan
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        default: .gray
        }
    }
}

