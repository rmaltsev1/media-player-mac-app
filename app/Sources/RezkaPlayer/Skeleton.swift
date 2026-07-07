import SwiftUI

/// A shimmering placeholder block. Used to build skeleton screens that make loads feel fast.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = Theme.tileRadius
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .quaternarySystemFill))
            .overlay(
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(60, w * 0.5))
                    .offset(x: animate ? w : -w * 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

/// One skeleton poster tile: poster block + two text lines, matching `PosterCard` metrics.
struct SkeletonPosterCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkeletonBox(cornerRadius: Theme.posterRadius)
                .aspectRatio(Theme.posterAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
            SkeletonBox(cornerRadius: 4).frame(height: 11).frame(maxWidth: .infinity)
            SkeletonBox(cornerRadius: 4).frame(width: 70, height: 9)
        }
    }
}

/// A full grid of skeleton tiles that mirrors `PosterGrid`'s layout while content loads.
struct SkeletonPosterGrid: View {
    var count: Int = 12
    private let columns = [GridItem(.adaptive(minimum: Theme.tileMin, maximum: Theme.tileMax),
                                    spacing: 18)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(0..<count, id: \.self) { _ in SkeletonPosterCard() }
        }
        .padding(20)
        .transition(.opacity)
    }
}

/// A horizontal skeleton row (for Continue Watching / Similar rails while loading).
struct SkeletonRow: View {
    var count: Int = 6
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonBox(cornerRadius: Theme.posterRadius)
                    .aspectRatio(Theme.posterAspect, contentMode: .fit)
                    .frame(width: 150)
            }
        }
    }
}
