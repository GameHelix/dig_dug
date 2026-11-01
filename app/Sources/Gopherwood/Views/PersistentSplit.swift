import SwiftUI

/// Two panes with a draggable divider whose position is remembered in UserDefaults (a window
/// choice that belongs to this Mac). SwiftUI's split views do not keep their positions.
struct PersistentSplit<First: View, Second: View>: View {
    let axis: Axis
    let minFirst: CGFloat
    let minSecond: CGFloat
    @AppStorage private var fraction: Double
    @ViewState private var dragStart: Double?
    private let first: First
    private let second: Second

    init(_ axis: Axis, key: String, defaultFraction: Double, minFirst: CGFloat, minSecond: CGFloat,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.minFirst = minFirst
        self.minSecond = minSecond
        _fraction = AppStorage(wrappedValue: defaultFraction, key)
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let size = clamp(CGFloat(fraction) * total, total: total)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: size)
                    handle(total: total)
                    second.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: size)
                    handle(total: total)
                    second.frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func clamp(_ value: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(minFirst, total - minSecond - 1)
        return min(max(value, minFirst), upper)
    }

    private func handle(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, 3)
            .contentShape(Rectangle())
            .padding(axis == .horizontal ? .horizontal : .vertical, -3)
            .pointerStyle(.frameResize(position: axis == .horizontal ? .trailing : .bottom))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    guard total > 0 else { return }
                    let start = dragStart ?? fraction
                    if dragStart == nil { dragStart = start }
                    let delta = axis == .horizontal ? drag.translation.width : drag.translation.height
                    fraction = Double(clamp(CGFloat(start) * total + delta, total: total) / total)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: fraction = min(0.85, fraction + 0.05)
                case .decrement: fraction = max(0.15, fraction - 0.05)
                @unknown default: break
                }
            }
    }
}
