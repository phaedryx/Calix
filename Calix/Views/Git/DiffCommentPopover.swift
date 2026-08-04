// DiffCommentPopover.swift
// Calix
//
// NSPopover-based inline comment editor for diff review.

import AppKit

@MainActor
final class DiffCommentPopoverController: NSViewController {
    enum Mode {
        case add
        case edit(existingText: String)
    }

    var onAdd: ((String) -> Void)?
    var onUpdate: ((String) -> Void)?
    var onDelete: (() -> Void)?
    weak var enclosingPopover: NSPopover?

    private let mode: Mode
    private let rangeHeader: String?
    private var textField: NSTextField!

    init(mode: Mode, rangeHeader: String? = nil) {
        self.mode = mode
        self.rangeHeader = rangeHeader
        super.init(nibName: nil, bundle: nil)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    
    override func loadView() {
        let containerHeight: CGFloat = rangeHeader != nil ? 100 : 80
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: containerHeight))

        // Range header label (if applicable)
        var headerLabel: NSTextField?
        if let rangeHeader {
            let label = NSTextField(labelWithString: rangeHeader)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            container.addSubview(label)
            headerLabel = label
        }

        textField = NSTextField(frame: .zero)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholderString = "Add review comment..."
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.target = self
        textField.action = #selector(textFieldAction)
        container.addSubview(textField)

        if case .edit(let existingText) = mode {
            textField.stringValue = existingText
        }

        // Buttons
        let buttonStack = NSStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        switch mode {
        case .add:
            let addButton = NSButton(title: "Add Comment", target: self, action: #selector(addAction))
            addButton.bezelStyle = .push
            addButton.keyEquivalent = "\r"
            let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
            cancelButton.bezelStyle = .push
            cancelButton.keyEquivalent = "\u{1b}" // Escape
            buttonStack.addArrangedSubview(cancelButton)
            buttonStack.addArrangedSubview(addButton)

        case .edit:
            let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteAction))
            deleteButton.bezelStyle = .push
            deleteButton.contentTintColor = .systemRed
            let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
            cancelButton.bezelStyle = .push
            cancelButton.keyEquivalent = "\u{1b}"
            let updateButton = NSButton(title: "Update", target: self, action: #selector(updateAction))
            updateButton.bezelStyle = .push
            updateButton.keyEquivalent = "\r"
            buttonStack.addArrangedSubview(deleteButton)
            buttonStack.addArrangedSubview(NSView()) // spacer
            buttonStack.addArrangedSubview(cancelButton)
            buttonStack.addArrangedSubview(updateButton)
        }

        container.addSubview(buttonStack)

        // Auto Layout
        if let headerLabel {
            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                textField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            ])
        }

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttonStack.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 8),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
        ])

        container.setAccessibilityIdentifier(AccessibilityID.DiffReview.commentPopover)
        self.view = container
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textField)
    }
    
    @objc private func textFieldAction() {
        // Enter pressed in text field
        switch mode {
        case .add: addAction()
        case .edit: updateAction()
        }
    }
    
    @objc private func addAction() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAdd?(text)
        closePopover()
    }
    
    @objc private func updateAction() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onUpdate?(text)
        closePopover()
    }
    
    @objc private func deleteAction() {
        onDelete?()
        closePopover()
    }
    
    @objc private func cancelAction() {
        closePopover()
    }

    private func closePopover() {
        enclosingPopover?.close()
    }
}
