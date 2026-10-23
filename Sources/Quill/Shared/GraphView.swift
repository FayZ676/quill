import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The library as a web of notes, as in Obsidian: a dot for each note and a line for each
/// link, pulled into shape by a little physics. Drag or swipe with two fingers to pan, pinch
/// to zoom, drag a dot to move it, and click one to open the note. Double-click the background to fit it all in.
struct GraphView: View {
    let graph: LinkGraph
    /// The note open in the editor, drawn in the accent.
    let current: URL?
    let open: (URL) -> Void

    @Environment(\.editorFont) private var font
    @StateObject private var sim = GraphSimulation()
    /// Follows the layout as it settles, until the view is panned or zoomed by hand.
    @State private var fitting = true
    @State private var scale: CGFloat = 1
    /// Where the world's origin sits, from the middle of the view.
    @State private var offset = CGSize.zero
    @State private var drag: Drag?
    @State private var pinchStart: CGFloat?
    @State private var hovered: Int?
    @State private var lastBackgroundTap = Date.distantPast

    private enum Drag {
        case node(Int, moved: Bool)
        case pan(from: CGSize)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let view = transform(in: size)
            Canvas { context, _ in
                draw(in: context, view)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size))
            .simultaneousGesture(pinchGesture(size))
            #if os(macOS)
            .background(ScrollWheelReader { delta in
                holdView(size)
                offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
            })
            #endif
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = node(at: point, view)
                case .ended: hovered = nil
                }
            }
        }
        .background(Color(platform: Theme.background))
        .overlay(alignment: .bottom) {
            if graph.notes.isEmpty {
                hint("No notes yet")
            } else if graph.links.isEmpty {
                hint("Link notes with [[Note name]] to connect them")
            }
        }
        .onAppear { sim.load(graph) }
        .onDisappear { sim.stop() }
        .onChange(of: graph) { sim.load($0) }
        #if os(macOS)
        .onChange(of: hovered) { node in
            if node != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        #endif
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .appFont(13, relativeTo: .footnote)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 16)
            .allowsHitTesting(false)
    }

    // MARK: Drawing

    /// Maps the simulation's world onto the view.
    private struct Transform {
        let center: CGPoint
        let scale: CGFloat

        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }
        func world(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - center.x) / scale, y: (p.y - center.y) / scale) }
    }

    private func transform(in size: CGSize) -> Transform {
        _ = sim.frame
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        guard fitting else {
            return Transform(center: CGPoint(x: middle.x + offset.width, y: middle.y + offset.height), scale: scale)
        }
        let bounds = sim.bounds
        let room = max(1, min(size.width, size.height) - 120)
        let fit = min(2, room / max(bounds.width, bounds.height, 1))
        return Transform(center: CGPoint(x: middle.x - bounds.midX * fit, y: middle.y - bounds.midY * fit), scale: fit)
    }

    private func draw(in context: GraphicsContext, _ view: Transform) {
        let points = sim.points
        guard points.count == sim.names.count else { return }
        let focus = hovered.map { sim.neighbors[$0].union([$0]) }
        let accent = Color(platform: Theme.accent)
        let quiet = Color(platform: Theme.markup)

        var faint = Path(), lit = Path()
        for link in sim.links {
            let a = view.screen(points[link.a]), b = view.screen(points[link.b])
            if let hovered, link.a == hovered || link.b == hovered {
                lit.move(to: a); lit.addLine(to: b)
            } else {
                faint.move(to: a); faint.addLine(to: b)
            }
        }
        context.stroke(faint, with: .color(quiet.opacity(focus == nil ? 0.45 : 0.15)), lineWidth: 1)
        context.stroke(lit, with: .color(accent.opacity(0.8)), lineWidth: 1.5)

        // Labels come in as you zoom closer, as in Obsidian; the hovered note and its
        // neighbors always have theirs.
        let labelOpacity = min(1, max(0, (view.scale - 0.55) / 0.35))
        for i in points.indices {
            let p = view.screen(points[i])
            let r = radius(i, view)
            let inFocus = focus?.contains(i) ?? true
            let color: Color = i == hovered || sim.urls[i] == current ? accent
                : focus != nil && inFocus ? Color(platform: Theme.text) : quiet
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color.opacity(inFocus ? 1 : 0.3)))

            let opacity = focus != nil ? (inFocus ? 1 : labelOpacity * 0.3) : labelOpacity
            guard opacity > 0 else { continue }
            let label = Text(sim.names[i])
                .font(.quill(font, size: 11))
                .foregroundColor(Color(platform: Theme.text).opacity(opacity * (inFocus && focus != nil ? 1 : 0.75)))
            context.draw(label, at: CGPoint(x: p.x, y: p.y + r + 4), anchor: .top)
        }
    }

    /// Notes with more links are drawn larger.
    private func radius(_ i: Int, _ view: Transform) -> CGFloat {
        let world = 4 + 1.4 * min(sqrt(CGFloat(sim.neighbors[i].count)), 6)
        return max(2.5, world * min(view.scale, 1.6))
    }

    private func node(at point: CGPoint, _ view: Transform) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, p) in sim.points.enumerated() {
            let s = view.screen(p)
            let d = hypot(s.x - point.x, s.y - point.y)
            if d <= max(radius(i, view) + 3, 8), d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    // MARK: Gestures

    /// Stops following the layout and keeps the view where it is now, so it can be moved by hand.
    private func holdView(_ size: CGSize) {
        guard fitting else { return }
        let view = transform(in: size)
        scale = view.scale
        offset = CGSize(width: view.center.x - size.width / 2, height: view.center.y - size.height / 2)
        fitting = false
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let view = transform(in: size)
                let moved = hypot(value.translation.width, value.translation.height) > 4
                switch drag {
                case nil:
                    if let i = node(at: value.startLocation, view) {
                        drag = .node(i, moved: false)
                    } else {
                        holdView(size)
                        drag = .pan(from: offset)
                    }
                case .node(let i, let wasMoved):
                    guard moved || wasMoved else { return }
                    drag = .node(i, moved: true)
                    sim.pin(i, at: view.world(value.location))
                case .pan(let start):
                    offset = CGSize(width: start.width + value.translation.width,
                                    height: start.height + value.translation.height)
                }
            }
            .onEnded { value in
                switch drag {
                case .node(let i, let moved):
                    sim.release()
                    if !moved { open(sim.urls[i]) }
                case .pan where hypot(value.translation.width, value.translation.height) < 4:
                    if Date().timeIntervalSince(lastBackgroundTap) < 0.35 {
                        fitting = true
                    }
                    lastBackgroundTap = Date()
                default:
                    break
                }
                drag = nil
            }
    }

    private func pinchGesture(_ size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { amount in
                holdView(size)
                let start = pinchStart ?? scale
                pinchStart = start
                let new = min(6, max(0.1, start * amount))
                // Zoom about the middle of the view.
                offset = CGSize(width: offset.width * new / scale, height: offset.height * new / scale)
                scale = new
            }
            .onEnded { _ in pinchStart = nil }
    }
}

/// Lays the graph out with forces, as d3-force does: every note pushes the others away,
/// links pull their ends together, and a weak pull toward the middle keeps lone notes near.
/// Runs until it settles, then stops; dragging a note stirs it again.
final class GraphSimulation: ObservableObject {
    /// Bumped each step, so the view redraws.
    @Published private(set) var frame = 0
    private(set) var urls: [URL] = []
    private(set) var names: [String] = []
    private(set) var points: [CGPoint] = []
    private(set) var links: [LinkGraph.Pair] = []
    private(set) var neighbors: [Set<Int>] = []

    private var velocities: [CGVector] = []
    private var alpha: CGFloat = 1
    private var alphaTarget: CGFloat = 0
    private var pinned: (index: Int, at: CGPoint)?
    private var timer: Timer?

    private static let linkLength: CGFloat = 50
    private static let charge: CGFloat = 120

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Takes a new graph, keeping notes it already had where they were.
    func load(_ graph: LinkGraph) {
        let old = Dictionary(zip(urls, points), uniquingKeysWith: { a, _ in a })
        urls = graph.notes
        names = urls.map(FileNode.displayName)
        links = graph.links
        neighbors = Array(repeating: [], count: urls.count)
        for link in links {
            neighbors[link.a].insert(link.b)
            neighbors[link.b].insert(link.a)
        }
        // Newcomers start on a sunflower spiral, which spreads them evenly.
        points = urls.enumerated().map { i, url in
            if let p = old[url] { return p }
            let r = 12 * sqrt(0.5 + CGFloat(i)), angle = CGFloat(i) * .pi * (3 - sqrt(5))
            return CGPoint(x: r * cos(angle), y: r * sin(angle))
        }
        velocities = Array(repeating: .zero, count: urls.count)
        pinned = nil
        alpha = old.isEmpty ? 1 : max(alpha, 0.3)
        start()
    }

    func pin(_ i: Int, at p: CGPoint) {
        pinned = (i, p)
        alphaTarget = 0.3
        start()
    }

    func release() {
        pinned = nil
        alphaTarget = 0
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        alpha += (alphaTarget - alpha) * 0.0228
        if alpha < 0.002 && alphaTarget == 0 {
            stop()
            return
        }
        let n = points.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                if dx == 0 && dy == 0 { dx = CGFloat.random(in: -0.5...0.5); dy = CGFloat.random(in: -0.5...0.5) }
                let d2 = max(dx * dx + dy * dy, 25)
                let f = Self.charge * alpha / d2
                velocities[i].dx += dx * f; velocities[i].dy += dy * f
                velocities[j].dx -= dx * f; velocities[j].dy -= dy * f
            }
        }
        for link in links {
            let dx = points[link.b].x - points[link.a].x, dy = points[link.b].y - points[link.a].y
            let d = max(sqrt(dx * dx + dy * dy), 0.01)
            let f = (d - Self.linkLength) / d * alpha * 0.25
            velocities[link.a].dx += dx * f; velocities[link.a].dy += dy * f
            velocities[link.b].dx -= dx * f; velocities[link.b].dy -= dy * f
        }
        for i in 0..<n {
            velocities[i].dx -= points[i].x * 0.06 * alpha
            velocities[i].dy -= points[i].y * 0.06 * alpha
            velocities[i].dx *= 0.6
            velocities[i].dy *= 0.6
            points[i].x += velocities[i].dx
            points[i].y += velocities[i].dy
        }
        if let pinned, pinned.index < n {
            points[pinned.index] = pinned.at
            velocities[pinned.index] = .zero
        }
        frame &+= 1
    }
}

private extension Color {
    init(platform color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}
