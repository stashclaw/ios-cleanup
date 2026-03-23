import SwiftUI

// MARK: - DuckCard

struct DuckCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Color.duckCream, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: Color.duckPink.opacity(0.08), radius: 8, x: 0, y: 3)
    }
}

// MARK: - DuckPrimaryButton

struct DuckPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.duckButton)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    LinearGradient(
                        colors: [Color.duckPink, Color(red: 0.831, green: 0.271, blue: 0.541)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 50)
                )
                .shadow(color: Color.duckPink.opacity(0.35), radius: 12, x: 0, y: 4)
        }
    }
}

// MARK: - DuckOutlineButton

struct DuckOutlineButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.duckButton)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 50))
                .overlay(
                    RoundedRectangle(cornerRadius: 50)
                        .strokeBorder(color, lineWidth: 1.5)
                )
        }
    }
}

// MARK: - DuckBadge

struct DuckBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.duckLabel)
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
    }
}

// MARK: - DuckSectionHeader

struct DuckSectionHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.duckHeading)
                .foregroundStyle(Color.duckBerry)
            Rectangle()
                .fill(Color.duckSoftPink)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DuckProgressBar

struct DuckProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.duckSoftPink)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * min(max(progress, 0), 1), height: 6)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
    }
}
