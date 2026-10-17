import AppKit
import SwiftUI

/// Where the items of the Choose list are: rows (list view) or cells (icon view), and where
/// their tick boxes are.
struct ItemLayout: Equatable {
    enum Style: Equatable { case list, grid }
    var style: Style
    var count: Int
    var rowHeight: CGFloat = 40
    /// Icon view: each cell's size, how many to a row, and the margin around the grid.
    var cell = CGSize(width: 1, height: 1)
    var columns = 1
    var inset: CGFloat = 0

    /// Where the tick boxes are in the list (from its left edge).
    static let tickColumn: CGFloat = 46
    /// The tick box in a cell's top-left corner, from the cell's corner.
    static let cellTick: CGFloat = 36

    static func list(count: Int, rowHeight: CGFloat) -> ItemLayout { ItemLayout(style: .list, count: count, rowHeight: rowHeight) }

    func index(at point: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        switch style {
        case .list:
            let index = Int(point.y / rowHeight)
            return point.y >= 0 && index < count ? index : nil
        case .grid:
            let x = point.x - inset, y = point.y - inset
            guard x >= 0, y >= 0 else { return nil }
            let column = Int(x / cell.width), row = Int(y / cell.height)
            guard column < columns else { return nil }
            let index = row * columns + column
            return index < count ? index : nil
        }
    }

    /// The item nearest the point (for painting ticks past the ends).
    func clamped(_ point: CGPoint) -> Int {
        guard count > 0 else { return 0 }
        switch style {
        case .list:
            return min(max(Int(point.y / rowHeight), 0), count - 1)
        case .grid:
            let column = min(max(Int((point.x - inset) / cell.width), 0), columns - 1)
            let row = max(Int((point.y - inset) / cell.height), 0)
            return min(row * columns + column, count - 1)
        }
    }

    func isTick(_ point: CGPoint) -> Bool {
        switch style {
        case .list:
            return point.x < Self.tickColumn
        case .grid:
            guard let index = index(at: point) else { return false }
            let frame = cellFrame(index)
            return point.x - frame.minX < Self.cellTick && point.y - frame.minY < Self.cellTick
        }
    }

    func cellFrame(_ index: Int) -> CGRect {
        switch style {
        case .list:
            return CGRect(x: 0, y: CGFloat(index) * rowHeight, width: 400, height: rowHeight)
        case .grid:
            return CGRect(x: inset + CGFloat(index % columns) * cell.width, y: inset + CGFloat(index / columns) * cell.height,
                          width: cell.width, height: cell.height)
        }
    }

    /// Where the item's picture is (drag images start there).
    func iconFrame(_ index: Int) -> CGRect {
        let frame = cellFrame(index)
        switch style {
        case .list:
            return CGRect(x: 60, y: frame.minY + 5, width: 30, height: 30)
        case .grid:
            let side = cell.height - 80
            return CGRect(x: frame.midX - side / 2, y: frame.minY + 14, width: side, height: side)
        }
    }
}

/// Mouse handling for the Choose list, in AppKit: clicks (with the real click count, so a double
/// click opens a file without making single clicks wait), painting ticks by dragging, dragging
/// files out to Finder, hover, and the right-click menu.
///
/// - Ticks change only on the tick boxes: dragging from one paints ticks over the items
///   crossed (and pulling out of the list then drags them out).
/// - Dragging an item anywhere else drags it out to Finder: every ticked item when it is
///   ticked, otherwise that item (file promises: Pulli copies them from the phone when dropped).
struct ListMouse: NSViewRepresentable {
    var layout: ItemLayout
    var isTicked: (Int) -> Bool
    var click: (_ row: Int, _ onTick: Bool, _ flags: NSEvent.ModifierFlags, _ clickCount: Int) -> Void
    var paint: (_ from: Int, _ to: Int) -> Void
    var paintEnded: () -> Void
    var hover: (Int?) -> Void
    /// The drag items for a drag starting on `row` (the ticked items, or that row), or nil.
    var dragItems: (_ row: Int) -> [NSDraggingItem]
    var menu: (_ row: Int) -> NSMenu?
    /// Edit › Copy (⌘C) and Paste (⌘V) while the list has the keyboard; nil when there is
    /// nothing to copy, or nothing to paste.
    var copyItems: (() -> Void)?
    var pasteItems: (() -> Void)?

    func makeNSView(context: Context) -> ListMouseView {
        let view = ListMouseView()
        view.owner = self
        return view
    }

    func updateNSView(_ view: ListMouseView, context: Context) {
        view.owner = self
    }
}

final class ListMouseView: NSView, NSDraggingSource, NSMenuItemValidation {
    var owner: ListMouse?
    private enum Mode { case idle, pressed, painting, dragging }
    private var mode = Mode.idle
    private var start = CGPoint.zero
    private var startRow = 0
    private var startOnTick = false
    private var clickCount = 1
    private var tracking: NSTrackingArea?
    /// A folder opens on the first click; the second click of that double click lands on the
    /// new folder's list, and must not open whatever row is under it.
    private let created = Date()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Keyboard: copy and paste (the search field keeps its own while it is typed in)

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Takes the keyboard when nothing else has it, so ⌘C and ⌘V work straight away.
        if let window, window.firstResponder === window { window.makeFirstResponder(self) }
    }

    @objc func copy(_ sender: Any?) { owner?.copyItems?() }
    @objc func paste(_ sender: Any?) { owner?.pasteItems?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): owner?.copyItems != nil
        case #selector(paste(_:)): owner?.pasteItems != nil
        default: true
        }
    }

    private func row(at point: CGPoint) -> Int? {
        owner?.layout.index(at: point)
    }

    private func clampedRow(_ point: CGPoint) -> Int {
        owner?.layout.clamped(point) ?? 0
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = row(at: point) else { mode = .idle; return }
        if event.clickCount > 1, Date().timeIntervalSince(created) < NSEvent.doubleClickInterval + 0.15 { mode = .idle; return }
        start = point
        startRow = index
        startOnTick = owner?.layout.isTick(point) ?? false
        clickCount = event.clickCount
        mode = .pressed
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .pressed:
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
            if startOnTick {
                mode = .painting
                owner.paint(startRow, clampedRow(point))
            } else {
                beginDrag(event, row: startRow)
            }
        case .painting:
            if !bounds.insetBy(dx: -2, dy: -40).contains(point), point.x < bounds.minX || point.x > bounds.maxX {
                // Painted, then pulled out of the list: drag what is now ticked.
                owner.paintEnded()
                beginDrag(event, row: startRow)
                return
            }
            owner.paint(startRow, clampedRow(point))
            autoscroll(with: event)
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mode = .idle }
        switch mode {
        case .pressed:
            owner?.click(startRow, startOnTick, event.modifierFlags, clickCount)
        case .painting:
            owner?.paintEnded()
        default:
            break
        }
    }

    private func beginDrag(_ event: NSEvent, row: Int) {
        guard let owner else { return }
        let items = owner.dragItems(row)
        guard !items.isEmpty else { mode = .idle; return }
        mode = .dragging
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mode = .idle
    }

    // MARK: Hover and menu

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.hover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        owner?.hover(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return owner?.menu(index)
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
