import AppKit

/// The menu's top (spec 2026-10-16 "The menu's top"), drawn from a
/// `ModeHeader.Model`: Off | Screen | Lid tabs, the running mode's chips and
/// a caption. AppKit controls, not SwiftUI hosting, because they track the
/// mouse reliably inside an `NSMenuItem.view`. An open menu passes no key
/// events to a custom view, so the header is mouse- and VoiceOver-operated.
///
/// The view never shows a click as done on its own: a tab or chip click
/// puts the control back to the model and reports the click; the
/// controller's refresh then calls `update` with the real state.
@MainActor
final class ModeHeaderView: NSView {
    static let minimumWidth: CGFloat = 260

    let segments: NSSegmentedControl
    private(set) var chipButtons: [NSButton] = []
    let captionLabel: NSTextField

    private var model: ModeHeader.Model
    private let onTab: @MainActor (ModeHeader.Tab) -> Void
    private let onChip: @MainActor (ModeHeader.ChipAction) -> Void
    private let stack = NSStackView()
    private let chipRow = NSStackView()

    init(model: ModeHeader.Model,
         onTab: @escaping @MainActor (ModeHeader.Tab) -> Void,
         onChip: @escaping @MainActor (ModeHeader.ChipAction) -> Void) {
        self.model = model
        self.onTab = onTab
        self.onChip = onChip
        segments = NSSegmentedControl(labels: ModeHeader.tabTitles, trackingMode: .selectOne, target: nil, action: nil)
        captionLabel = NSTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 80))

        segments.target = self
        segments.action = #selector(tabChanged(_:))
        segments.segmentDistribution = .fillEqually
        for (index, title) in ModeHeader.tabTitles.enumerated() {
            segments.setToolTip(title, forSegment: index)
        }
        segments.setAccessibilityLabel("Mode")

        captionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        captionLabel.textColor = .secondaryLabelColor

        chipRow.orientation = .horizontal
        chipRow.spacing = 4
        chipRow.alignment = .centerY

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.addArrangedSubview(segments)
        stack.addArrangedSubview(chipRow)
        stack.addArrangedSubview(captionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            segments.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            segments.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ model: ModeHeader.Model) {
        self.model = model
        apply()
    }

    private func apply() {
        segments.selectedSegment = model.selected.rawValue
        if chipButtons.map(\.title) != model.chips.map(\.title) {
            for button in chipButtons { chipRow.removeArrangedSubview(button); button.removeFromSuperview() }
            chipButtons = model.chips.enumerated().map { index, chip in
                let button = NSButton(title: chip.title, target: self, action: #selector(chipClicked(_:)))
                button.bezelStyle = .recessed
                button.setButtonType(.pushOnPushOff)
                button.controlSize = .small
                button.tag = index
                chipRow.addArrangedSubview(button)
                return button
            }
        }
        for (button, chip) in zip(chipButtons, model.chips) {
            button.state = chip.isSelected ? .on : .off
            button.setAccessibilityLabel(chip.accessibilityLabel)
            button.toolTip = chip.accessibilityLabel
        }
        chipRow.isHidden = model.chips.isEmpty
        captionLabel.stringValue = model.caption
        layoutSubtreeIfNeeded()
        let fitting = fittingSize
        setFrameSize(NSSize(width: max(fitting.width, Self.minimumWidth), height: fitting.height))
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let clicked = ModeHeader.Tab(rawValue: sender.selectedSegment)
        // Back to the real mode until the controller says otherwise.
        sender.selectedSegment = model.selected.rawValue
        guard let clicked else { return }
        onTab(clicked)
    }

    @objc private func chipClicked(_ sender: NSButton) {
        guard model.chips.indices.contains(sender.tag) else { return }
        let chip = model.chips[sender.tag]
        sender.state = chip.isSelected ? .on : .off
        // A chip is the last step: close the menu, then act.
        enclosingMenuItem?.menu?.cancelTracking()
        onChip(chip.action)
    }
}
