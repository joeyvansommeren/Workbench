import AppKit
import SwiftUI

/// A native outline backed by the same visible rows as the SwiftUI sidebar.
/// It is not mounted until every row action has an accessible equivalent.
@MainActor
final class SidebarTreeAccessibilityOutline: NSView {
  private(set) var rows: [SidebarTreeAccessibilityElement] = []
  private final class WeakAnchor {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }
  private var elementsByID: [String: SidebarTreeAccessibilityElement] = [:]
  private var anchorsByID: [String: WeakAnchor] = [:]
  private var pendingFocusID: String?
  var selectedID: String?
  var onSelect: (String) -> Void = { _ in }

  func update(_ hierarchy: [SidebarTreeAccessibilityRow]) {
    let visibleIDs = Set(hierarchy.map(\.id))
    for (id, element) in elementsByID where !visibleIDs.contains(id) {
      element.deactivate()
    }
    // The previous selection closure can capture rows that no longer exist.
    onSelect = { _ in }
    for item in hierarchy {
      let element = elementsByID[item.id] ?? SidebarTreeAccessibilityElement(id: item.id)
      element.owner = self
      element.isActive = true
      element.level = item.level
      element.anchor = anchorsByID[item.id]?.view
      elementsByID[item.id] = element
    }
    rows = hierarchy.compactMap { elementsByID[$0.id] }
    if let pendingFocusID, !rows.contains(where: { $0.id == pendingFocusID }) {
      self.pendingFocusID = nil
    }
    for (index, item) in hierarchy.enumerated() {
      guard let element = elementsByID[item.id] else { continue }
      element.index = index
      element.parentRow = item.parentID.flatMap { elementsByID[$0] }
      element.childRows = []
    }
    for element in rows { element.parentRow?.childRows.append(element) }
  }

  func configure(
    rows sourceRows: [SidebarTreeRow],
    selectedID: String?,
    sessionsByRepo: [String: [SessionNode]],
    sessionsByBranch: [String: [SessionNode]],
    registry: SidebarTreeAccessibilityRegistry,
    actions: any SidebarTreeActionHandling,
    onLoadMore: @escaping (LoadMoreRowModel) -> Void,
    onFocus: @escaping (String) -> Void
  ) {
    let previousIDs = rows.map(\.id)
    let previousSelection = self.selectedID
    let previousExpanded = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isExpanded) })
    update(SidebarTreeRows.accessibilityHierarchy(sourceRows))
    self.selectedID = selectedID
    onSelect = { id in
      guard case .session(let model) = sourceRows.first(where: { $0.id == id }) else { return }
      actions.open(model.node)
    }
    for row in sourceRows {
      guard let element = elementsByID[row.id] else { continue }
      element.onFocus = { [weak self] in
        self?.pendingFocusID = row.id
        onFocus(row.id)
        self?.notifyFocusWhenVisible(row.id)
      }
      element.canExpand = false
      element.isExpanded = false
      element.onPress = { false }
      element.onDisclosure = { _ in }
      element.commands = []
      element.approvalAccessibility = { nil }
      switch row {
      case .repo(let model):
        element.label = model.name
        if model.isCollapsed, model.attentionCount > 0 {
          element.label += ", \(model.attentionCount) need attention"
        }
        element.commands = repositoryMenuEntries(
          model: model, sessions: sessionsByRepo[model.path] ?? [], actions: actions)
        element.canExpand = true
        element.isExpanded = !model.isCollapsed
        element.onDisclosure = { actions.setRepository(model, collapsed: !$0) }
        element.onPress = {
          actions.setRepository(model, collapsed: !model.isCollapsed)
          return true
        }
      case .branch(let model):
        element.label = model.name
        if let pullRequest = model.decoration?.pullRequest {
          element.label +=
            ", " + BranchPullRequestBadge(pullRequest: pullRequest).accessibilityDescription
        }
        element.commands = branchMenuEntries(
          model: model, sessions: sessionsByBranch[model.id] ?? [], actions: actions)
        element.isExpanded = true
      case .session(let model):
        element.label = model.sidebarAccessibilityLabel
        element.commands = sessionMenuEntries(
          node: model.node, actions: actions,
          onShowResult: { registry.showResult(for: model.id) },
          canShowResult: { registry.hasCallbacks(for: model.id) })
        if model.node.showsApprovePill {
          element.approvalAccessibility = {
            let phase = actions.approvalPhase(for: model.node)
            let presentation = actions.approvalPresentation(for: model.node)
            return (
              SidebarApprovePillText.accessibilityLabel(
                toolName: model.node.pendingToolName, presentation: presentation),
              SidebarApprovePillText.isBusy(phase) ? "Sending" : ""
            )
          }
        }
        if model.node.showsApprovePill || model.node.showsAnswerPill {
          let title = model.node.showsApprovePill ? "Review request" : "Answer"
          element.commands.insert(
            .command(
              SidebarMenuCommand(
                id: model.node.showsApprovePill ? "reviewRequest" : "answer",
                title: title, systemImage: "bubble.left",
                isAvailable: {
                  guard model.node.showsApprovePill else { return true }
                  return !SidebarApprovePillText.isBusy(actions.approvalPhase(for: model.node))
                }
              ) { actions.open(model.node) }), at: 0)
        }
        element.onPress = {
          actions.open(model.node)
          return true
        }
      case .loadMore(let model):
        element.label = "Show older sessions"
        element.onPress = {
          onLoadMore(model)
          return true
        }
      }
    }
    if window != nil {
      if previousIDs != rows.map(\.id) {
        NSAccessibility.post(element: self, notification: .rowCountChanged)
      }
      for element in rows where previousExpanded[element.id] != nil {
        if previousExpanded[element.id] != element.isExpanded, element.canExpand {
          NSAccessibility.post(
            element: element, notification: element.isExpanded ? .rowExpanded : .rowCollapsed)
        }
      }
      if previousSelection != selectedID {
        NSAccessibility.post(element: self, notification: .selectedRowsChanged)
      }
    }
  }

  fileprivate func notifyFocusWhenVisible(_ id: String) {
    guard pendingFocusID == id else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.pendingFocusID == id, let row = self.elementsByID[id], row.isVisible
      else { return }
      self.pendingFocusID = nil
      NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
    }
  }

  func registerAnchor(_ anchor: NSView, for id: String) {
    anchorsByID[id] = WeakAnchor(anchor)
    elementsByID[id]?.anchor = anchor
    if pendingFocusID == id { notifyFocusWhenVisible(id) }
  }

  func unregisterAnchor(_ anchor: NSView, for id: String) {
    guard anchorsByID[id]?.view === anchor else { return }
    anchorsByID.removeValue(forKey: id)
    elementsByID[id]?.anchor = nil
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .outline }
  override func accessibilityLabel() -> String? { "Sessions" }
  override func accessibilityRows() -> [Any]? { rows }
  override func accessibilityChildren() -> [Any]? { rows }
  override func accessibilityVisibleRows() -> [Any]? {
    rows.filter(\.isVisible)
  }
  override func accessibilitySelectedRows() -> [Any]? { rows.filter { $0.id == selectedID } }
  override func setAccessibilitySelectedRows(_ values: [Any]?) {
    guard let row = values?.first as? SidebarTreeAccessibilityElement,
      row.owner === self, row.isVisible
    else { return }
    onSelect(row.id)
  }
  override func accessibilityHitTest(_ point: NSPoint) -> Any? {
    rows.first { $0.isVisible && $0.accessibilityFrame().contains(point) } ?? self
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class SidebarTreeAccessibilityElement: NSAccessibilityElement,
  @preconcurrency NSAccessibilityRow
{
  let id: String
  weak var owner: SidebarTreeAccessibilityOutline?
  weak var anchor: NSView?
  weak var parentRow: SidebarTreeAccessibilityElement?
  var childRows: [SidebarTreeAccessibilityElement] = []
  var level = 0
  var index = 0
  var isActive = false
  var label = ""
  var approvalAccessibility: () -> (label: String, value: String)? = { nil }
  var isExpanded = false
  var canExpand = false
  var onDisclosure: (Bool) -> Void = { _ in }
  var onPress: () -> Bool = { false }
  var onFocus: () -> Void = {}
  private var menuTargets: [SidebarTreeAccessibilityMenuTarget] = []
  var commands: [SidebarMenuEntry] = []

  init(id: String) {
    self.id = id
    super.init()
  }
  /// Retain only the row's identity when its source leaves the visible tree.
  func deactivate() {
    isActive = false
    anchor = nil
    parentRow = nil
    childRows = []
    label = ""
    approvalAccessibility = { nil }
    isExpanded = false
    canExpand = false
    onDisclosure = { _ in }
    onPress = { false }
    onFocus = {}
    commands = []
    menuTargets = []
  }

  override func isAccessibilityElement() -> Bool { isActive }
  override func accessibilityRole() -> NSAccessibility.Role? { .row }
  override func accessibilityParent() -> Any? { owner }
  override func accessibilityIdentifier() -> String { id }
  override func accessibilityLabel() -> String? {
    guard let approval = approvalAccessibility() else { return label }
    return label + ", " + approval.label
  }
  override func accessibilityValue() -> Any? { approvalAccessibility()?.value }
  override func accessibilityFrame() -> NSRect {
    guard let anchor, let window = anchor.window else { return .zero }
    return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
  }
  var isVisible: Bool {
    guard isActive, anchor?.window != nil, let owner else { return false }
    let frame = accessibilityFrame()
    return !frame.isEmpty && owner.accessibilityFrame().intersects(frame)
  }
  override func accessibilityIndex() -> Int { index }
  override func accessibilityDisclosureLevel() -> Int { level }
  override func accessibilityDisclosedByRow() -> Any? { isActive ? parentRow : nil }
  override func accessibilityDisclosedRows() -> Any? { isActive && isExpanded ? childRows : [] }
  override func isAccessibilityDisclosed() -> Bool { isActive && isExpanded }
  override func setAccessibilityDisclosed(_ value: Bool) {
    if isActive, canExpand, isVisible { onDisclosure(value) }
  }
  override func isAccessibilitySelected() -> Bool { isActive && owner?.selectedID == id }
  override func setAccessibilitySelected(_ value: Bool) {
    if isActive, value, isVisible { owner?.onSelect(id) }
  }
  override func setAccessibilityFocused(_ value: Bool) {
    if isActive, value { onFocus() }
  }
  override func accessibilityPerformPress() -> Bool {
    guard isVisible else { return false }
    return onPress()
  }
  override func accessibilityPerformShowMenu() -> Bool {
    guard let anchor, isVisible, !commands.isEmpty else { return false }
    let menu = NSMenu()
    menuTargets = []
    for entry in commands {
      switch entry {
      case .separator:
        menu.addItem(.separator())
      case .command(let command):
        let id = command.id
        let target = SidebarTreeAccessibilityMenuTarget { [weak self] in
          _ = self?.performCommand(id: id)
        }
        let item = NSMenuItem(
          title: command.title, action: #selector(target.invoke), keyEquivalent: "")
        item.target = target
        item.isEnabled = command.isAvailable()
        menuTargets.append(target)
        menu.addItem(item)
      }
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    menuTargets = []
    return true
  }
  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    return commands.compactMap { entry in
      guard case .command(let command) = entry else { return nil }
      let id = command.id
      return NSAccessibilityCustomAction(name: command.title) { [weak self] in
        self?.performCommand(id: id) ?? false
      }
    }
  }
  func performCommand(id: String) -> Bool {
    performSidebarMenuCommand(id: id, entries: commands, isVisible: isVisible)
  }
  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == #selector(setAccessibilityDisclosed(_:)) { return canExpand }
    return super.isAccessibilitySelectorAllowed(selector)
  }
}

@MainActor
private final class SidebarTreeAccessibilityMenuTarget: NSObject {
  let action: () -> Void
  init(action: @escaping () -> Void) { self.action = action }
  @objc func invoke() { action() }
}

/// A row-sized AppKit anchor for accessibility frames. It never participates in hit testing.
struct SidebarTreeAccessibilityAnchor: NSViewRepresentable {
  let id: String
  let outline: SidebarTreeAccessibilityOutline

  func makeCoordinator() -> Coordinator { Coordinator(id: id, outline: outline) }

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    view.rowID = id
    view.outline = outline
    outline.registerAnchor(view, for: id)
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.rowID = id
    view.outline = outline
    outline.registerAnchor(view, for: id)
  }

  static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
    coordinator.outline?.unregisterAnchor(view, for: coordinator.id)
  }

  final class Coordinator {
    let id: String
    weak var outline: SidebarTreeAccessibilityOutline?
    init(id: String, outline: SidebarTreeAccessibilityOutline) {
      self.id = id
      self.outline = outline
    }
  }

  final class AnchorView: NSView {
    var rowID = ""
    weak var outline: SidebarTreeAccessibilityOutline?
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
      super.layout()
      outline?.notifyFocusWhenVisible(rowID)
    }
  }
}

/// The row owns the callbacks; the registry never keeps an offscreen row alive.
@MainActor
final class SidebarTreeAccessibilityRowCallbacks {
  var showResult: () -> Void = {}
}

@MainActor
final class SidebarTreeAccessibilityRegistry {
  private final class WeakCallbacks {
    weak var value: SidebarTreeAccessibilityRowCallbacks?
    init(_ value: SidebarTreeAccessibilityRowCallbacks) { self.value = value }
  }
  private var callbacks: [String: WeakCallbacks] = [:]

  func register(_ value: SidebarTreeAccessibilityRowCallbacks, for id: String) {
    callbacks[id] = WeakCallbacks(value)
  }

  func unregister(_ value: SidebarTreeAccessibilityRowCallbacks, for id: String) {
    guard callbacks[id]?.value === value else { return }
    callbacks.removeValue(forKey: id)
  }

  func hasCallbacks(for id: String) -> Bool { callbacks[id]?.value != nil }

  @discardableResult
  func showResult(for id: String) -> Bool {
    guard let value = callbacks[id]?.value else { return false }
    value.showResult()
    return true
  }
}

private struct SidebarTreeAccessibilityRegistryKey: EnvironmentKey {
  static let defaultValue: SidebarTreeAccessibilityRegistry? = nil
}

extension EnvironmentValues {
  var sidebarTreeAccessibilityRegistry: SidebarTreeAccessibilityRegistry? {
    get { self[SidebarTreeAccessibilityRegistryKey.self] }
    set { self[SidebarTreeAccessibilityRegistryKey.self] = newValue }
  }
}
