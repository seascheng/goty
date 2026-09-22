import SwiftUI
import Combine

/// Wraps a Ghostty surface view in an NSScrollView to provide native macOS scrollbar support.
///
/// ## Coordinate System
/// AppKit uses a +Y-up coordinate system (origin at bottom-left), while terminals conceptually
/// use +Y-down (row 0 at top). This class handles the inversion when converting between row
/// offsets and pixel positions.
///
/// ## Architecture
/// - `scrollView`: The outermost NSScrollView that manages scrollbar rendering and behavior
/// - `documentView`: A blank NSView whose height represents total scrollback (in pixels)
/// - `surfaceView`: The actual Ghostty renderer, positioned to fill the visible rect
class SurfaceScrollView: NSView {
    private let scrollView: NSScrollView
    private let documentView: NSView
    private let surfaceView: Ghostty.SurfaceView
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Manual-stream hosts defer grid changes until an ordered Size marker.
    /// Ordinary EXEC surfaces keep the default frame-driven behavior.
    var synchronizesCoreSurface = true
    private var isLiveScrolling = false

    /// The last row position sent via scroll_to_row action. Used to avoid
    /// sending redundant actions when the user drags the scrollbar but stays
    /// on the same row.
    private var lastSentRow: Int?

    init(contentSize: CGSize, surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        // The scroll view is our outermost view that controls all our scrollbar
        // rendering and behavior.
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Always use the overlay style. See mouseMoved for how we make
        // it usable without a scroll wheel or gestures.
        scrollView.scrollerStyle = .overlay
        // hide default background to show blur effect properly
        scrollView.drawsBackground = false
        // don't let the content view clip its subviews, to enable the
        // surface to draw the background behind non-overlay scrollers
        // (we currently only use overlay scrollers, but might as well
        // configure the views correctly in case we change our mind)
        scrollView.contentView.clipsToBounds = false

        // The document view is what the scrollview is actually going
        // to be directly scrolling. We set it up to a "blank" NSView
        // with the desired content size.
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = documentView

        // The document view contains our actual surface as a child.
        // We synchronize the scrolling of the document with this surface
        // so that our primary Ghostty renderer only needs to render the viewport.
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        // Our scroll view is our only view
        addSubview(scrollView)

        // Apply initial scrollbar settings
        synchronizeAppearance()

        // We listen for scroll events through bounds notifications on our NSClipView.
        // This is based on: https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollChange(notification)
        })

        // Listen for scrollbar updates from Ghostty
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        // Listen for live scroll events
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isLiveScrolling = false
            // goty: while live-scrolling we refuse programmatic
            // position updates, so a viewport that moved meanwhile (a
            // resize re-evaluating the pin, output) leaves the knob and
            // the rendered content disagreeing. Converge once scrolling
            // ends — the core state wins.
            self.synchronizeScrollView()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            // Since this observer is used to immediately override the event
            // that produced the notification, we let it run synchronously on
            // the posting thread.
            queue: nil
        ) { [weak self] _ in
            self?.handleScrollerStyleChange()
        })


        // Listen for derived config changes to update scrollbar settings live
        surfaceView.$derivedConfig
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.handleConfigChange()
                }
            }
            .store(in: &cancellables)
        surfaceView.$pointerStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in
                self?.scrollView.documentCursor = newStyle.cursor
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // The entire bounds is a safe area, so we override any default
    // insets. This is necessary for the content view to match the
    // surface view if we have the "hidden" titlebar style.
    override var safeAreaInsets: NSEdgeInsets { return NSEdgeInsetsZero }

    override func layout() {
        super.layout()

        // Fill entire bounds with scroll view
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size

        // We only set the width of the documentView here, as the height depends
        // on the scrollbar state and is updated in synchronizeScrollView
        documentView.frame.size.width = scrollView.bounds.width

        // When our scrollview changes make sure our scroller and surface views are synchronized
        synchronizeScrollView()
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    // MARK: Scrolling

    private func synchronizeAppearance() {
        let scrollbarConfig = surfaceView.derivedConfig.scrollbar
        scrollView.hasVerticalScroller = scrollbarConfig != .never
        let hasLightBackground = OSColor(surfaceView.derivedConfig.backgroundColor).isLightColor
        // Make sure the scroller’s appearance matches the surface's background color.
        scrollView.appearance = NSAppearance(named: hasLightBackground ? .aqua : .darkAqua)
        updateTrackingAreas()
    }

    /// Positions the surface view to fill the currently visible rectangle.
    ///
    /// This is called whenever the scroll position changes. The surface view (which does the
    /// actual terminal rendering) always fills exactly the visible portion of the document view,
    /// so the renderer only needs to render what's currently on screen.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Inform the actual pty of our size change. This doesn't change the actual view
    /// frame because we do want to render the whole thing, but it will prevent our
    /// rows/cols from going into the non-content area.
    private func synchronizeCoreSurface() {
        guard synchronizesCoreSurface else { return }
        // Only update the pty if we have a valid (non-zero) content size. The content size
        // can be zero when this is added early to a view, or to an invisible hierarchy.
        // Practically, this happened in the quick terminal.
        let width = scrollView.contentSize.width
        let height = surfaceView.frame.height
        if width > 0 && height > 0 {
            surfaceView.sizeDidChange(CGSize(width: width, height: height))
        }
    }

    /// Sizes the document view and scrolls the content view according to the scrollbar state
    private func synchronizeScrollView() {
        // Update the document height to give our scroller the correct proportions
        documentView.frame.size.height = documentHeight()

        // Only update our actual scroll position if we're not actively scrolling.
        if !isLiveScrolling {
            // Convert row units to pixels using cell height, ignore zero height.
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                // Invert coordinate system: terminal offset is from top, AppKit position from bottom
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))

                // Track the current row position to avoid redundant movements when we
                // move the scrollbar.
                lastSentRow = Int(scrollbar.offset)
            }
        }

        // Always update our scrolled view with the latest dimensions
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Notifications

    /// Handles bounds changes in the scroll view's clip view, keeping the surface view synchronized.
    private func handleScrollChange(_ notification: Notification) {
        synchronizeSurfaceView()
    }

    /// Handles scrollbar style changes
    private func handleScrollerStyleChange() {
        scrollView.scrollerStyle = .overlay
        synchronizeCoreSurface()
    }

    /// Handles config changes
    private func handleConfigChange() {
        synchronizeAppearance()
        synchronizeCoreSurface()
    }

    /// Handles live scroll events (user actively dragging the scrollbar).
    ///
    /// Converts the current scroll position to a row number and sends a `scroll_to_row` action
    /// to the terminal core. Only sends actions when the row changes to avoid IPC spam.
    private func handleLiveScroll() {
        // If our cell height is currently zero then we avoid a div by zero below
        // and just don't scroll (there's no where to scroll anyways). This can
        // happen with a tiny terminal.
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        // AppKit views are +Y going up, so we calculate from the bottom
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height

        // goty: elastic overscroll (rubber-band) and mid-update
        // document heights produce rows outside the valid range, and
        // scroll_to_row treats anything at-or-past the bottom band as
        // "jump to active" — a bounce could fling the viewport to the
        // bottom while the user scrolled up. Clamp into [0, total-len].
        if let bar = surfaceView.scrollbar {
            let maxRow = Int(max(0, bar.total - bar.len))
            let clamped = min(max(Int(scrollOffset / cellHeight), 0), maxRow)

            // Only send action if the row changed to avoid action spam
            guard clamped != lastSentRow else { return }
            lastSentRow = clamped
            _ = surfaceView.surfaceModel?.perform(action: "scroll_to_row:\(clamped)")
        }
    }

    /// Handles scrollbar state updates from the terminal core.
    ///
    /// Updates the document view size to reflect total scrollback and adjusts scroll position
    /// to match the terminal's viewport. During live scrolling, updates document size but skips
    /// programmatic position changes to avoid fighting the user's drag.
    ///
    /// ## Scrollbar State
    /// The scrollbar struct contains:
    /// - `total`: Total rows in scrollback + active area
    /// - `offset`: First visible row (0 = top of history)
    /// - `len`: Number of visible rows (viewport height)
    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[SwiftUI.Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    // MARK: Calculations

    /// Calculate the appropriate document view height given a scrollbar state
    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }


    // MARK: Mouse events

    override func mouseMoved(with: NSEvent) {
        // When the OS preferred style is .legacy, the user should be able to
        // click and drag the scroller without using scroll wheels or gestures,
        // so we flash it when the mouse is moved over the scrollbar area.
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        // To update our tracking area we just recreate it all.
        trackingAreas.forEach { removeTrackingArea($0) }

        super.updateTrackingAreas()

        // Our tracking area is the scroller frame
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil))
    }
}
