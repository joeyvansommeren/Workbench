import CoreGraphics

/// Transient presentation only; closing a column never stops its session.
struct SessionColumnsState: Equatable {
  private(set) var itemIDs: [String] = []
  /// Share of the width per column slot. Kept by slot, not by session, so a
  /// session taking over a column keeps the width you dragged it to.
  private(set) var widthShares: [CGFloat] = []

  mutating func add(_ id: String, beside primary: String) {
    if itemIDs.isEmpty { itemIDs = [primary] }
    if !itemIDs.contains(id) { itemIDs.append(id) }
    // A new column gets an even share; the others shrink in proportion.
    syncShares(newShare: 1 / CGFloat(itemIDs.count))
  }

  mutating func remove(_ id: String) {
    guard let index = itemIDs.firstIndex(of: id) else { return }
    itemIDs.remove(at: index)
    if index < widthShares.count { widthShares.remove(at: index) }
    syncShares(newShare: 0)
  }

  mutating func retainAvailable(_ available: Set<String>) {
    for id in itemIDs where !available.contains(id) { remove(id) }
  }

  /// The primary session changed. A session already in a column just gets
  /// focus. One from outside takes over the column that was active, so an
  /// ordinary sidebar click never throws the arrangement away. Only an
  /// explicit "Close columns" exits.
  mutating func select(_ id: String?, replacing previous: String?) {
    guard let id, !itemIDs.isEmpty, !itemIDs.contains(id) else { return }
    if let previous, let index = itemIDs.firstIndex(of: previous) {
      itemIDs[index] = id
    } else {
      itemIDs[0] = id
    }
  }

  /// Drags the divider after column `index` by `delta` of the total width.
  /// Both neighbours stay at least `minShare` wide.
  mutating func resize(divider index: Int, from start: [CGFloat], by delta: CGFloat, minShare: CGFloat) {
    guard start.count == widthShares.count, index >= 0, index + 1 < start.count else { return }
    let pair = start[index] + start[index + 1]
    let floor = min(minShare, pair / 2)
    let left = max(floor, min(pair - floor, start[index] + delta))
    widthShares = start
    widthShares[index] = left
    widthShares[index + 1] = pair - left
  }

  private mutating func syncShares(newShare: CGFloat) {
    let existing = Array(widthShares.prefix(itemIDs.count))
    let added = itemIDs.count - existing.count
    let existingTotal = existing.reduce(0, +)
    let room = 1 - newShare * CGFloat(added)
    let scaled = existingTotal > 0 ? existing.map { $0 / existingTotal * room } : existing
    widthShares = scaled + Array(repeating: newShare, count: added)
    if itemIDs.isEmpty { widthShares = [] }
  }
}
