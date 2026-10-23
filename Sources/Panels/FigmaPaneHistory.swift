import Foundation

/// cmux-rbf (#cm-73.3, step 5): one Back and Forward history across a Figma pane's
/// two pages, the preview and the editor. Reject a revert of this file on upstream sync.
///
/// **Tom's rule** (2026-10-20 15:51, applied to the pointing rule and narrowed on
/// 2026-10-22): `⌘[`, a mouse's back button, and every other entrance but a trackpad
/// swipe go where he was. From an editor he came to from the preview, Back shows that
/// preview; on the preview, Back walks the boards the agent pointed at, in order; Back
/// into an editor a pointing dropped reopens it at its saved address, which is a reload.
/// Forward is the reverse. A swipe keeps WebKit's own Back within each page, and this
/// history follows wherever the swipe left that page.
///
/// **A place is one stop the pane showed:** a side, the address to load it from again,
/// and the entry of one web view's own back list that shows it (`Item`, WebKit's
/// `WKBackForwardListItem`). WebKit keeps an entry's identity across Back, Forward, a
/// swipe and a load of the address it already shows, and drops the entry when a new
/// load replaces it (measured 2026-10-22, fix round 3, phase A). So a place whose entry
/// is still in its web view's list is shown by moving WebKit's list to it, and any other
/// place is loaded again from its address. A place being loaded has no entry until its
/// load commits; a place a restart restored never has one.
///
/// A new place (Tom's switch, a pointing, *Open in Figma*, or a page navigating itself)
/// drops every place after the current one, as a browser does.
///
/// Pure: the panel owns the web views, tells this what each one shows, and asks it where to go.
struct FigmaPaneHistory<Item: AnyObject> {
    enum Side: Equatable {
        case preview
        case editor
    }

    struct Place {
        let side: Side
        /// Where to load the place from when its entry is gone.
        var address: URL
        /// The web view that shows, or last showed, this place.
        var page: UUID?
        /// The entry in that web view's own list that shows this place.
        var item: Item?
        /// A load of this place started from the entry `pendingFrom`; the entry its commit adds is this place's.
        var pending: Bool
        var pendingFrom: Item?
    }

    private(set) var places: [Place] = []
    private(set) var index = 0
    /// The file the history belongs to; another file in the pane ends it.
    private(set) var fileKey: String?

    var isActive: Bool { !places.isEmpty }
    var current: Place? { isActive ? places[index] : nil }
    var canGoBackAcross: Bool { index > 0 }
    var canGoForwardAcross: Bool { index + 1 < places.count }

    mutating func reset() {
        self = FigmaPaneHistory()
    }

    /// The pane's first places: what the showing page held before, with the showing one at `index`.
    mutating func start(fileKey: String, places: [Place], index: Int) {
        guard self.places.isEmpty, places.indices.contains(index) else { return }
        self.fileKey = fileKey
        self.places = places
        self.index = index
    }

    /// A new place after the current one, shown in `page`. With `item`, the page shows it
    /// already; else `page` is loading it, from the entry `from` that page showed.
    mutating func push(side: Side, address: URL, page: UUID, item: Item?, from: Item?) {
        guard isActive else { return }
        places.removeSubrange((index + 1)...)
        // A load of the board this place already shows (a repeat goto) keeps WebKit's entry: the same place.
        if let item, places[index].page == page, places[index].item === item, places[index].side == side {
            places[index].address = address
            return
        }
        if item == nil { endPending(on: page) }
        places.append(Place(side: side, address: address, page: page, item: item, pending: item == nil, pendingFrom: from))
        index = places.count - 1
    }

    /// The current place is shown again: by `item` already in `page`, or by a load into `page` from `from`.
    mutating func shown(page: UUID, item: Item?, from: Item?) {
        guard isActive else { return }
        if item == nil { endPending(on: page) }
        places[index].page = page
        places[index].item = item
        places[index].pending = item == nil
        places[index].pendingFrom = from
    }

    /// What `page` shows now: `current` is its entry, `atEnd` says nothing is forward of it.
    /// A load this history started there takes the entry its commit added; a known entry
    /// (a swipe, WebKit's own Back) moves the history to its place; an entry nobody knows,
    /// at the end of the list, is the page navigating itself: a new place.
    mutating func follow(page: UUID, current: Item?, atEnd: Bool, side: Side?, address: URL?) {
        guard isActive, let current else { return }
        settle(page: page, current: current, atEnd: atEnd)
        if places[index].page == page, places[index].item === current { return }
        let matches = places.indices.filter { places[$0].page == page && places[$0].item === current }
        if let nearest = matches.min(by: { abs($0 - index) < abs($1 - index) }) {
            index = nearest
            return
        }
        guard atEnd, places[index].page == page, !places[index].pending,
              let side, side == places[index].side, let address else { return }
        places.removeSubrange((index + 1)...)
        places.append(Place(side: side, address: address, page: page, item: current, pending: false, pendingFrom: nil))
        index = places.count - 1
    }

    /// A load this history started in `page` is over once `page` shows an entry other than the one it
    /// started from. Its place takes that entry only when the load added it: a new entry at the end of the
    /// list that no other place holds. An older entry means a move (a key press, a swipe) cancelled the
    /// load; the place keeps no entry and loads from its address when shown. Moves nothing.
    mutating func settle(page: UUID, current: Item?, atEnd: Bool) {
        guard let current else { return }
        let heldByAPlace = places.contains { $0.page == page && $0.item === current }
        for i in places.indices where places[i].page == page && places[i].pending && places[i].pendingFrom !== current {
            if atEnd, !heldByAPlace { places[i].item = current }
            places[i].pending = false
        }
    }

    /// The current place's latest address, as its page moves; nil, or an address on the
    /// other side, keeps the one it has.
    mutating func leave(address: URL?, side: Side?) {
        guard isActive, let address, side == places[index].side else { return }
        places[index].address = address
    }

    /// The place before the current one, now current; nil at the first place.
    mutating func back() -> Place? {
        guard index > 0 else { return nil }
        index -= 1
        return places[index]
    }

    /// The place after the current one, now current; nil at the newest place.
    mutating func forward() -> Place? {
        guard index + 1 < places.count else { return nil }
        index += 1
        return places[index]
    }

    /// Whether a load this history started in `page` from `from` is still on its way there.
    func hasLoadInFlight(page: UUID, from: Item?) -> Bool {
        places.contains { $0.page == page && $0.pending && $0.pendingFrom === from }
    }

    /// The panel moved `page` to another entry, which cancels a load this history started there.
    mutating func loadsCancelled(on page: UUID) {
        endPending(on: page)
    }

    /// A page starts one load at a time: an earlier load there that has not committed never will.
    private mutating func endPending(on page: UUID) {
        for i in places.indices where places[i].page == page && places[i].pending {
            places[i].pending = false
        }
    }
}
