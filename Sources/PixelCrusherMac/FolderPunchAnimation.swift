import SwiftUI

struct FolderPunchAnimation: View {
    let folderName: String

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 90)
                    .foregroundStyle(Color.yellow.opacity(0.92))

                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isAnimating ? 32 : -18))
                    .offset(x: isAnimating ? 32 : -42, y: isAnimating ? 22 : -16)
                    .scaleEffect(isAnimating ? 1.03 : 0.75)
                    .opacity(isAnimating ? 1.0 : 0)
                    .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 2)
                    .animation(.interpolatingSpring(stiffness: 230, damping: 15).delay(0.03), value: isAnimating)

                Capsule()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 90, height: 8)
                    .blur(radius: 2)
                    .offset(y: 62)
                    .scaleEffect(x: isAnimating ? 1.06 : 0.55, y: 1, anchor: .center)
                    .opacity(isAnimating ? 0.15 : 0.08)
                    .animation(.easeOut(duration: 1.0), value: isAnimating)
            }
            .frame(width: 220, height: 150)

            Text("Dropped folder")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(folderName)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: 340)
        .onAppear {
            isAnimating = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.default) {
                    isAnimating = true
                }
            }
        }
    }
}

#Preview {
    FolderPunchAnimation(folderName: "Photos Session")
}
