import SwiftUI
import AppKit

// MARK: - ResizableContainer
// Ermöglicht das stufenlose Skalieren (Größe ziehen) von Ansichten wie WebViews oder Bildern.

struct ResizableContainer<Content: View>: View {
    @State private var height: CGFloat
    @State private var width: CGFloat?
    
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let minWidth: CGFloat?
    let maxWidth: CGFloat?
    let content: () -> Content
    
    @State private var dragBaseHeight: CGFloat? = nil
    @State private var dragBaseWidth: CGFloat? = nil
    @State private var isHoveringHandle = false
    
    init(initialHeight: CGFloat = 320, minHeight: CGFloat = 100, maxHeight: CGFloat = 1200,
         initialWidth: CGFloat? = nil, minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self._height = State(initialValue: initialHeight)
        self._width = State(initialValue: initialWidth)
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.content = content
    }
    
    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(height: height)
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : width)
            
            // Drag Handle Bar (Bottom)
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(isHoveringHandle ? 0.2 : 0.08))
                    .frame(height: 12)
                
                Image(systemName: width != nil ? "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left" : "line.3.horizontal")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringHandle = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragBaseHeight == nil { dragBaseHeight = height }
                        if let baseH = dragBaseHeight {
                            let newHeight = baseH + value.translation.height
                            height = max(minHeight, min(newHeight, maxHeight))
                        }
                        
                        if width != nil {
                            if dragBaseWidth == nil { dragBaseWidth = width }
                            if let baseW = dragBaseWidth {
                                let newWidth = baseW + value.translation.width
                                let minW = minWidth ?? 100
                                let maxW = maxWidth ?? 2000
                                width = max(minW, min(newWidth, maxW))
                            }
                        }
                    }
                    .onEnded { _ in
                        dragBaseHeight = nil
                        dragBaseWidth = nil
                    }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
