//import Auth
//import InlineKit
//import UIKit
//
//// MARK: - Custom Flow Layout for Reactions
//class ReactionFlowLayout: UICollectionViewFlowLayout {
//    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
//        guard let originalAttributes = super.layoutAttributesForElements(in: rect)?.map({ $0.copy() }) as? [UICollectionViewLayoutAttributes] else {
//            return nil
//        }
//        
//        // Track position for each row
//        var leftMargin = sectionInset.left
//        var maxY: CGFloat = -1.0
//        
//        for attributes in originalAttributes where attributes.representedElementCategory == .cell {
//            // Start new row if needed
//            if attributes.frame.origin.y >= maxY {
//                leftMargin = sectionInset.left
//            }
//            
//            // Position cell on the left edge
//            attributes.frame.origin.x = leftMargin
//            leftMargin += attributes.frame.width + minimumInteritemSpacing
//            maxY = max(attributes.frame.maxY, maxY)
//        }
//        
//        return originalAttributes
//    }
//}
//
//// MARK: - Reaction Cell
//class ReactionCell: UICollectionViewCell {
//    static let reuseIdentifier = "ReactionCell"
//    
//    // UI Elements
//    private let emojiLabel = UILabel()
//    private let countLabel = UILabel()
//    private let stackView = UIStackView()
//    
//    override init(frame: CGRect) {
//        super.init(frame: frame)
//        setupViews()
//    }
//    
//    required init?(coder: NSCoder) {
//        super.init(coder: coder)
//        setupViews()
//    }
//    
//    private func setupViews() {
//        // Configure labels
//        emojiLabel.font = .systemFont(ofSize: 17)
//        countLabel.font = .systemFont(ofSize: 13)
//        countLabel.textColor = .secondaryLabel
//        
//        // Configure stack view
//        stackView.axis = .horizontal
//        stackView.spacing = 4
//        stackView.alignment = .center
//        stackView.translatesAutoresizingMaskIntoConstraints = false
//        
//        // Add to hierarchy
//        stackView.addArrangedSubview(emojiLabel)
//        stackView.addArrangedSubview(countLabel)
//        contentView.addSubview(stackView)
//        
//        // Style content view
//        contentView.backgroundColor = .systemGray6
//        contentView.layer.cornerRadius = 14
//        
//        // Layout
//        NSLayoutConstraint.activate([
//            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
//            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
//            
//            // Fixed size like the SwiftUI version
//            contentView.widthAnchor.constraint(equalToConstant: 45),
//            contentView.heightAnchor.constraint(equalToConstant: 26)
//        ])
//    }
//    
//    func configure(with emoji: String, count: Int) {
//        emojiLabel.text = emoji
//        countLabel.text = "\(count)"
//    }
//}
//
//class ReactionsCollectionView: UICollectionView, UICollectionViewDelegate, UICollectionViewDataSource {
//    private var reactions: [Reaction] = []
//    
//    // Processed reactions data
//    private var reactionsDict: [(emoji: String, count: Int)] {
//        var dict = [String: Int]()
//        for reaction in reactions {
//            dict[reaction.emoji, default: 0] += 1
//        }
//        return dict.sorted { $0.value > $1.value }
//    }
//    
//    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
//        let flowLayout = ReactionFlowLayout()
//        flowLayout.scrollDirection = .vertical
//        flowLayout.minimumInteritemSpacing = 6
//        flowLayout.minimumLineSpacing = 6
//        
//        super.init(frame: frame, collectionViewLayout: flowLayout)
//        
//        setup()
//    }
//    
//    required init?(coder: NSCoder) {
//        let flowLayout = ReactionFlowLayout()
//        flowLayout.scrollDirection = .vertical
//        flowLayout.minimumInteritemSpacing = 6
//        flowLayout.minimumLineSpacing = 6
//        
//        super.init(coder: coder)
//        
//        setup()
//    }
//    
//    private func setup() {
//        backgroundColor = .clear
//        isScrollEnabled = false
//        translatesAutoresizingMaskIntoConstraints = false
//        
//        register(ReactionCell.self, forCellWithReuseIdentifier: ReactionCell.reuseIdentifier)
//        
//        dataSource = self
//        delegate = self
//    }
//    
//    func updateReactions(_ reactions: [Reaction]) {
//        self.reactions = reactions
//        reloadData()
//        
//        // Adjust height constraint based on content
//        invalidateIntrinsicContentSize()
//    }
//    
//    override var intrinsicContentSize: CGSize {
//        return contentSize
//    }
//    
//    // MARK: - UICollectionViewDataSource
//    
//    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
//        return reactionsDict.count
//    }
//    
//    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
//        guard let cell = collectionView.dequeueReusableCell(
//            withReuseIdentifier: ReactionCell.reuseIdentifier,
//            for: indexPath
//        ) as? ReactionCell else {
//            fatalError("Unable to dequeue ReactionCell")
//        }
//        
//        let reaction = reactionsDict[indexPath.item]
//        cell.configure(with: reaction.emoji, count: reaction.count)
//        
//        return cell
//    }
//}
