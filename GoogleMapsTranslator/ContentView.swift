import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)

                Text("Google Maps Translator")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Translate text from Google Maps photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 16) {
                    InstructionRow(number: 1, text: "Open Google Maps and view a Place")
                    InstructionRow(number: 2, text: "Tap on a photo to view it")
                    InstructionRow(number: 3, text: "Tap the Share button")
                    InstructionRow(number: 4, text: "Select \"Translate\" from the share sheet")
                }
                .padding()
                .background(.regularMaterial)
                .cornerRadius(16)

                Spacer()
                Spacer()
            }
            .padding()
        }
    }
}

struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.blue))
                .foregroundStyle(.white)
            Text(text)
                .font(.body)
        }
    }
}
