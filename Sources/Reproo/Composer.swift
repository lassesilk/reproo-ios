#if canImport(UIKit)
import UIKit

/// The offline composer's texts – nb for Norwegian devices (nb/nn/no, like the widget), else English.
struct ComposerStrings: Equatable {
    let title: String
    let banner: String
    /** The page did not load although the device is not known to be offline (slow, or the platform did not answer). */
    let bannerUnreachable: String
    let messageLabel: String
    let screenshotLabel: String
    let screenshotDescription: String
    let removeScreenshot: String
    let name: String
    let email: String
    let optional: String
    let save: String
    let cancel: String
    let saved: String
    let done: String
    let fullTitle: String
    let fullMessage: String
    let failedTitle: String
    let failedMessage: String
    let ok: String
    let offlineTitle: String
    let offlineMessage: String
    let close: String
    let assistantNotice: String
    let privacyLink: String

    static let norwegian = ComposerStrings(
        title: "Meld inn problem",
        banner: "Du er uten nett. Rapporten lagres på telefonen og sendes automatisk når du får nett igjen.",
        bannerUnreachable: "Rapportsiden svarer ikke akkurat nå. Rapporten lagres på telefonen og sendes automatisk.",
        messageLabel: "Hva skjedde? Hva prøvde du å gjøre?",
        screenshotLabel: "Skjermbilde",
        screenshotDescription: "Skjermbilde av skjermen du var på",
        removeScreenshot: "Fjern skjermbilde",
        name: "Navn",
        email: "E-post",
        optional: "valgfritt",
        save: "Lagre",
        cancel: "Avbryt",
        saved: "Lagret – sendes automatisk når du har nett.",
        done: "Ferdig",
        fullTitle: "Kan ikke lagre flere rapporter",
        fullMessage: "20 rapporter venter allerede på å bli sendt. Koble til nettet så de blir sendt, og prøv igjen.",
        failedTitle: "Rapporten ble ikke lagret",
        failedMessage: "Telefonen kunne ikke lagre rapporten. Prøv igjen.",
        ok: "OK",
        offlineTitle: "Du er uten nett",
        offlineMessage: "Spørsmålene vises igjen neste gang appen har nett.",
        close: "Lukk",
        assistantNotice: "Eventuelle spørsmål om rapporten stilles av en AI-assistent.",
        privacyLink: "Personvern"
    )

    static let english = ComposerStrings(
        title: "Report a problem",
        banner: "You're offline. The report is saved on the phone and sent automatically when you're back online.",
        bannerUnreachable: "The report page isn't responding right now. The report is saved on the phone and sent automatically.",
        messageLabel: "What happened? What were you trying to do?",
        screenshotLabel: "Screenshot",
        screenshotDescription: "Screenshot of the screen you were on",
        removeScreenshot: "Remove screenshot",
        name: "Name",
        email: "Email",
        optional: "optional",
        save: "Save",
        cancel: "Cancel",
        saved: "Saved – it will be sent automatically when you're online.",
        done: "Done",
        fullTitle: "Can't save more reports",
        fullMessage: "20 reports are already waiting to be sent. Connect to the internet so they can be sent, then try again.",
        failedTitle: "The report wasn't saved",
        failedMessage: "The phone couldn't save the report. Please try again.",
        ok: "OK",
        offlineTitle: "You're offline",
        offlineMessage: "The questions will show again next time the app is online.",
        close: "Close",
        assistantNotice: "Any questions about the report are asked by an AI assistant.",
        privacyLink: "Privacy"
    )

    static func forLocale(_ locale: String) -> ComposerStrings {
        CrashPromptStrings.forLocale(locale) == .norwegian ? .norwegian : .english
    }
}

/// What the tester wrote in the composer.
struct ComposerInput: Equatable {
    let message: String
    let name: String?
    let email: String?
    let includeScreenshot: Bool

    /// `{name?, email?}` – only what was filled in.
    var reporter: [String: String]? {
        var reporter: [String: String] = [:]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { reporter["name"] = name }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { reporter["email"] = email }
        return reporter.isEmpty ? nil : reporter
    }
}

/// The native report form used without a connection: what happened (required), the screenshot
/// (shown, removable) and – when the project asks for them – name and e-mail, and a line saying the
/// questions come from an AI assistant, with the privacy notice. Dynamic Type, VoiceOver, light and dark
/// mode, and the keyboard never covers the field being edited.
final class ComposerViewController: UIViewController, UITextViewDelegate, UITextFieldDelegate {
    private let strings: ComposerStrings
    private let screenshot: UIImage?
    private let fields: ProjectConfigCache.Fields
    private let privacyNotice: URL?
    private let prefilledName: String?
    private let prefilledEmail: String?
    /// The page did not load while the device is not known to be offline: never «you're offline».
    private let pageUnreachable: Bool

    /// Returns whether the report was saved (the composer then stays until the container replaces it).
    var onSave: ((ComposerInput) -> OfflineReports.SaveResult)?
    var onCancel: (() -> Void)?
    /// Something was written: the sheet should not close by a swipe.
    var onDirtyChange: ((Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    let messageView = UITextView()
    private let nameField = UITextField()
    private let emailField = UITextField()
    private var screenshotSection: UIView?
    private(set) var includesScreenshot: Bool
    private lazy var saveButton = UIBarButtonItem(title: strings.save, style: .done, target: self, action: #selector(save))

    init(strings: ComposerStrings, screenshot: UIImage?, fields: ProjectConfigCache.Fields, privacyNotice: URL? = nil, name: String?, email: String?, pageUnreachable: Bool = false) {
        self.strings = strings
        self.pageUnreachable = pageUnreachable
        self.screenshot = screenshot
        self.fields = fields
        self.privacyNotice = privacyNotice
        self.prefilledName = name
        self.prefilledEmail = email
        self.includesScreenshot = screenshot != nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = strings.title
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: strings.cancel, style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = saveButton
        saveButton.isEnabled = false
        saveButton.accessibilityIdentifier = "reproo-composer-save"

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The keyboard's top: the scroll view shrinks above it, so every field can be scrolled into view.
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        stack.addArrangedSubview(banner())
        stack.addArrangedSubview(messageSection())
        if let screenshot {
            let section = screenshotSection(screenshot)
            screenshotSection = section
            stack.addArrangedSubview(section)
        }
        if fields.name.isShown {
            stack.addArrangedSubview(fieldSection(nameField, label: label(strings.name, mode: fields.name), text: prefilledName))
            nameField.textContentType = .name
            nameField.autocapitalizationType = .words
            nameField.accessibilityIdentifier = "reproo-composer-name"
        }
        if fields.email.isShown {
            stack.addArrangedSubview(fieldSection(emailField, label: label(strings.email, mode: fields.email), text: prefilledEmail))
            emailField.textContentType = .emailAddress
            emailField.keyboardType = .emailAddress
            emailField.autocapitalizationType = .none
            emailField.autocorrectionType = .no
            emailField.accessibilityIdentifier = "reproo-composer-email"
        }
        stack.addArrangedSubview(assistantNotice())
        // Return moves on to the next field; the last one closes the keyboard.
        let fieldsShown = [fields.name.isShown ? nameField : nil, fields.email.isShown ? emailField : nil].compactMap { $0 }
        for (index, field) in fieldsShown.enumerated() {
            field.returnKeyType = index == fieldsShown.count - 1 ? .done : .next
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if messageView.text.isEmpty { messageView.becomeFirstResponder() }
    }

    // MARK: Sections

    private func banner() -> UIView {
        let message = pageUnreachable ? strings.bannerUnreachable : strings.banner
        let icon = UIImageView(image: UIImage(systemName: pageUnreachable ? "exclamationmark.icloud" : "wifi.slash"))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        let text = UILabel()
        text.text = message
        text.font = .preferredFont(forTextStyle: .subheadline)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = .label
        text.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 12
        row.alignment = .top
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = 12
        row.isAccessibilityElement = true
        row.accessibilityLabel = message
        row.accessibilityTraits = .staticText
        row.accessibilityIdentifier = "reproo-composer-banner"
        return row
    }

    private func messageSection() -> UIView {
        let title = sectionLabel(strings.messageLabel)
        // The text view carries the question itself, so VoiceOver reads it once, with the field.
        title.isAccessibilityElement = false
        messageView.font = .preferredFont(forTextStyle: .body)
        messageView.adjustsFontForContentSizeCategory = true
        messageView.textColor = .label
        messageView.backgroundColor = .secondarySystemBackground
        messageView.layer.cornerRadius = 10
        messageView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        messageView.isScrollEnabled = false
        messageView.delegate = self
        messageView.accessibilityLabel = strings.messageLabel
        messageView.accessibilityIdentifier = "reproo-composer-message"
        messageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        return verticalStack([title, messageView], spacing: 8)
    }

    private func screenshotSection(_ image: UIImage) -> UIView {
        let title = sectionLabel(strings.screenshotLabel)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 10
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = strings.screenshotDescription
        imageView.accessibilityTraits = .image
        imageView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        var configuration = UIButton.Configuration.plain()
        configuration.title = strings.removeScreenshot
        configuration.image = UIImage(systemName: "trash")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .systemRed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        configuration.titleTextAttributesTransformer = Self.dynamicFont(.body)
        let remove = UIButton(configuration: configuration)
        remove.contentHorizontalAlignment = .leading
        remove.accessibilityIdentifier = "reproo-composer-remove-screenshot"
        remove.addTarget(self, action: #selector(removeScreenshot), for: .touchUpInside)
        return verticalStack([title, imageView, remove], spacing: 8)
    }

    /// «The questions are asked by an AI assistant. Privacy» – the link opens the notice in the browser.
    private func assistantNotice() -> UIView {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let text = NSMutableAttributedString(string: strings.assistantNotice, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        if let privacyNotice {
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            text.append(NSAttributedString(string: strings.privacyLink, attributes: [.font: font, .link: privacyNotice]))
        }
        let notice = UITextView()
        notice.attributedText = text
        notice.isEditable = false
        notice.isScrollEnabled = false
        notice.backgroundColor = .clear
        notice.textContainerInset = .zero
        notice.textContainer.lineFragmentPadding = 0
        notice.adjustsFontForContentSizeCategory = true
        notice.accessibilityIdentifier = "reproo-composer-assistant-notice"
        return notice
    }

    private func fieldSection(_ field: UITextField, label text: String, text value: String?) -> UIView {
        let title = sectionLabel(text)
        title.isAccessibilityElement = false
        field.text = value
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.accessibilityLabel = text
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return verticalStack([title, field], spacing: 8)
    }

    private func label(_ text: String, mode: ProjectConfigCache.Mode) -> String {
        mode == .optional ? "\(text) (\(strings.optional))" : text
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        return label
    }

    /// Button titles that follow Dynamic Type.
    static func dynamicFont(_ style: UIFont.TextStyle) -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: style)
            return attributes
        }
    }

    private func verticalStack(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        return stack
    }

    // MARK: Actions

    var input: ComposerInput {
        ComposerInput(
            message: messageView.text,
            name: fields.name.isShown ? nameField.text : nil,
            email: fields.email.isShown ? emailField.text : nil,
            includeScreenshot: includesScreenshot
        )
    }

    @objc func save() {
        guard !messageView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        view.endEditing(true)
        switch onSave?(input) ?? .failed {
        case .saved:
            break
        case .full:
            showAlert(title: strings.fullTitle, message: strings.fullMessage)
        case .failed:
            showAlert(title: strings.failedTitle, message: strings.failedMessage)
        }
    }

    @objc private func cancel() {
        view.endEditing(true)
        onCancel?()
    }

    @objc func removeScreenshot() {
        includesScreenshot = false
        guard let section = screenshotSection else { return }
        UIView.animate(withDuration: 0.2) {
            section.isHidden = true
            section.alpha = 0
        }
        UIAccessibility.post(notification: .layoutChanged, argument: messageView)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.ok, style: .default))
        present(alert, animated: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        let written = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if saveButton.isEnabled != written {
            saveButton.isEnabled = written
            onDirtyChange?(written)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField, fields.email.isShown {
            emailField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }
}

/// A short native message in the report sheet: «Lagret – sendes automatisk …» after saving, or «Du er
/// uten nett» when a report's conversation cannot be loaded.
final class StatusPanelViewController: UIViewController {
    private let symbol: String
    private let symbolColor: UIColor
    private let headline: String
    private let message: String?
    private let buttonTitle: String
    var onButton: (() -> Void)?

    init(symbol: String, symbolColor: UIColor, title: String, message: String?, button: String) {
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.headline = title
        self.message = message
        self.buttonTitle = button
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func saved(_ strings: ComposerStrings) -> StatusPanelViewController {
        StatusPanelViewController(symbol: "checkmark.circle.fill", symbolColor: .systemGreen, title: strings.saved, message: nil, button: strings.done)
    }

    static func offline(_ strings: ComposerStrings) -> StatusPanelViewController {
        StatusPanelViewController(symbol: "wifi.slash", symbolColor: .secondaryLabel, title: strings.offlineTitle, message: strings.offlineMessage, button: strings.close)
    }

    private let titleLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = symbolColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle, scale: .large)
        icon.isAccessibilityElement = false
        titleLabel.text = headline
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        var views: [UIView] = [icon, titleLabel]
        if let message {
            let messageLabel = UILabel()
            messageLabel.text = message
            messageLabel.font = .preferredFont(forTextStyle: .body)
            messageLabel.adjustsFontForContentSizeCategory = true
            messageLabel.textColor = .secondaryLabel
            messageLabel.textAlignment = .center
            messageLabel.numberOfLines = 0
            views.append(messageLabel)
        }
        var configuration = UIButton.Configuration.filled()
        configuration.title = buttonTitle
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        configuration.titleTextAttributesTransformer = ComposerViewController.dynamicFont(.headline)
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "reproo-status-button"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        views.append(button)

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(28, after: views[views.count - 2])
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    @objc private func tapped() {
        onButton?()
    }
}
#endif
