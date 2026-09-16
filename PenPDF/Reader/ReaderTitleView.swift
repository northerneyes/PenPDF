import UIKit

/// Preview-style titleView for the Reader nav bar (FR-9, §7): a small
/// first-page thumbnail, the file name (without extension) on the first
/// line, and a live `n / N` page counter on a smaller line beneath it.
/// Nothing here is tappable — `isUserInteractionEnabled` is off.
final class ReaderTitleView: UIView {

    private let thumbnailView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "doc.text"))
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .secondaryLabel
        imageView.layer.cornerRadius = 3
        imageView.clipsToBounds = true
        // WP6 (deferred.md): a mostly-white first page makes the thumbnail
        // nearly invisible; a hairline border reads as a document icon.
        imageView.layer.borderWidth = 0.5
        imageView.layer.borderColor = UIColor.separator.cgColor
        return imageView
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let semibold = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        label.font = UIFont(descriptor: semibold, size: base.pointSize)
        return label
    }()

    private let counterLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    init(name: String) {
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = name

        let textStack = UIStackView(arrangedSubviews: [nameLabel, counterLabel])
        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 0

        let stack = UIStackView(arrangedSubviews: [thumbnailView, textStack])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 22),
            thumbnailView.heightAnchor.constraint(equalToConstant: 22),

            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Long file names truncate (nameLabel's compression resistance
            // above) instead of pushing the toolbar's other items off the bar.
            widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])

        // `UIColor.separator` is dynamic, but the `CGColor` snapshot on the
        // layer above does not track appearance changes on its own — refresh
        // it whenever the trait collection (e.g. light/dark) changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ReaderTitleView, _: UITraitCollection) in
            view.thumbnailView.layer.borderColor = UIColor.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Live `n / N` text (FR-9). Called from the Reader on every page change.
    func setCounter(_ text: String) {
        counterLabel.text = text
    }

    /// Rendered off the main thread by the Reader; falls back to the
    /// `doc.text` placeholder if `image` is `nil` (rendering failed).
    func setThumbnail(_ image: UIImage?) {
        thumbnailView.image = image ?? UIImage(systemName: "doc.text")
    }
}
