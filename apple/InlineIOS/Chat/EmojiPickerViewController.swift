import Foundation
import UIKit

class EmojiPickerViewController: UIViewController {
  var emojiSelectedHandler: ((String) -> Void)?
  private var collectionView: UICollectionView!
  private var displayedSections: [(title: String, emojis: [String])] = []

  // MARK: - View Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()

    setupUI()
    loadEmojis()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Show keyboard automatically if needed
    // searchBar.becomeFirstResponder()
  }

  // MARK: - Setup

  private func setupUI() {
    view.backgroundColor = .systemBackground

    // Create collection view layout
    let layout = UICollectionViewFlowLayout()
    let cellSize: CGFloat = 50
    layout.itemSize = CGSize(width: cellSize, height: cellSize)
    layout.minimumInteritemSpacing = 8
    layout.minimumLineSpacing = 8
    layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

    // Create collection view
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: "EmojiCell")
    collectionView.delegate = self
    collectionView.dataSource = self
    collectionView.keyboardDismissMode = .onDrag
    view.addSubview(collectionView)

    // Setup constraints
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
  }

  private func loadEmojis() {
    // Define emoji categories with their ranges
    let categories: [(name: String, ranges: [ClosedRange<Int>])] = [
      ("Smileys & Emotion", [0x1_F600 ... 0x1_F64F]),
      ("People & Body", [0x1_F466 ... 0x1_F487, 0x1_F48B ... 0x1_F4FF, 0x1_F90C ... 0x1_F9FF]),
      ("Animals & Nature", [0x1_F400 ... 0x1_F43F, 0x1_F980 ... 0x1_F9AF]),
      ("Food & Drink", [0x1_F32D ... 0x1_F37F, 0x1_F95F ... 0x1_F9CB]),
      ("Travel & Places", [0x1_F680 ... 0x1_F6FF, 0x1_F30D ... 0x1_F32C]),
      ("Activities", [0x1_F3A0 ... 0x1_F3FF, 0x26BD ... 0x26FF, 0x1_F94A ... 0x1_F94F]),
      ("Objects", [0x1_F4A1 ... 0x1_F4FF, 0x1_F500 ... 0x1_F53D, 0x1_F550 ... 0x1_F567, 0x1_F6D1 ... 0x1_F6DF]),
      ("Symbols", [0x1_F300 ... 0x1_F5FF, 0x1_F900 ... 0x1_F9FF]),
      ("Flags", [0x1_F1E6 ... 0x1_F1FF]),
    ]

    // Get all available emoji characters
    let allEmojis = (0x0000 ... 0x1F_FFFF).compactMap { UnicodeScalar($0) }
      .filter(\.properties.isEmoji)
      .map { String($0) }

    // Categorize emojis
    var categorizedEmojis: [(title: String, emojis: [String])] = []

    for category in categories {
      var categoryEmojis: [String] = []

      for emoji in allEmojis {
        if let firstScalar = emoji.unicodeScalars.first {
          let value = Int(firstScalar.value)
          if category.ranges.contains(where: { $0.contains(value) }) {
            categoryEmojis.append(emoji)
          }
        }
      }

      if !categoryEmojis.isEmpty {
        categorizedEmojis.append((title: category.name, emojis: categoryEmojis))
      }
    }

    // Add "Other" category for uncategorized emojis
    let categorizedEmojiSet = Set(categorizedEmojis.flatMap(\.emojis))
    let otherEmojis = allEmojis.filter { !categorizedEmojiSet.contains($0) }

    if !otherEmojis.isEmpty {
      categorizedEmojis.append((title: "Other", emojis: otherEmojis))
    }

    displayedSections = categorizedEmojis

    // Register header view
    collectionView.register(
      EmojiHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: "Header"
    )

    collectionView.reloadData()
  }
}

// MARK: - UICollectionView DataSource & Delegate

extension EmojiPickerViewController: UICollectionViewDataSource, UICollectionViewDelegate,
  UICollectionViewDelegateFlowLayout
{
  func numberOfSections(in collectionView: UICollectionView) -> Int {
    displayedSections.count
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    displayedSections[section].emojis.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EmojiCell", for: indexPath) as! EmojiCell
    cell.configure(with: displayedSections[indexPath.section].emojis[indexPath.item])
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  ) -> UICollectionReusableView {
    if kind == UICollectionView.elementKindSectionHeader {
      let header = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: "Header",
        for: indexPath
      ) as! EmojiHeaderView
      header.configure(with: displayedSections[indexPath.section].title)
      return header
    }
    return UICollectionReusableView()
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> CGSize {
    CGSize(width: collectionView.bounds.width, height: 32)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let emoji = displayedSections[indexPath.section].emojis[indexPath.item]
    emojiSelectedHandler?(emoji)
  }
}

// MARK: - Emoji Cell

class EmojiCell: UICollectionViewCell {
  private let emojiLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)

    emojiLabel.font = .systemFont(ofSize: 30)
    emojiLabel.textAlignment = .center
    emojiLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(emojiLabel)

    NSLayoutConstraint.activate([
      emojiLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      emojiLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      emojiLabel.widthAnchor.constraint(equalTo: contentView.widthAnchor),
      emojiLabel.heightAnchor.constraint(equalTo: contentView.heightAnchor),
    ])

    // Add tap feedback
    layer.cornerRadius = 10
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with emoji: String) {
    emojiLabel.text = emoji
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    animateHighlight(true)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    animateHighlight(false)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    animateHighlight(false)
  }

  private func animateHighlight(_ isHighlighted: Bool) {
    UIView.animate(withDuration: 0.1) {
      self.backgroundColor = isHighlighted ? .systemGray5 : .clear
      self.transform = isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
    }
  }
}

class EmojiHeaderView: UICollectionReusableView {
  let titleLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    titleLabel.font = .boldSystemFont(ofSize: 14)
    titleLabel.textColor = .systemGray
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)

    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with title: String) {
    titleLabel.text = title.uppercased()
  }
}
