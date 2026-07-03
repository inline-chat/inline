import InlineKit
import UIKit

final class AnimatedCompositionalLayout: UICollectionViewCompositionalLayout {
  private var sendAnimationSuppressedIndexPaths: Set<IndexPath> = []
  private var sendAnimationSuppressedAppearingItems: Set<MessageListItem> = []

  func suppressSendAnimationAppearingItems(
    _ items: Set<MessageListItem>,
    at indexPaths: Set<IndexPath>
  ) {
    sendAnimationSuppressedAppearingItems = items
    sendAnimationSuppressedIndexPaths = indexPaths
  }

  func clearSendAnimationAppearingItemSuppression() {
    sendAnimationSuppressedAppearingItems.removeAll(keepingCapacity: true)
    sendAnimationSuppressedIndexPaths.removeAll(keepingCapacity: true)
  }

  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes? {
    let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)

    if shouldSuppressSendAnimationAppearingItem(at: itemIndexPath) {
      guard let baseAttributes = layoutAttributesForItem(at: itemIndexPath) ?? attributes else {
        SendMessageAnimationDiagnostics.debug(
          "layout suppress-appearing-missing-attributes indexPath=\(itemIndexPath)"
        )
        return nil
      }
      guard let stableAttributes = baseAttributes.copy() as? UICollectionViewLayoutAttributes else {
        return baseAttributes
      }
      stableAttributes.alpha = 1
      stableAttributes.transform = .identity
      stableAttributes.transform3D = CATransform3DIdentity
      return stableAttributes
    }

    guard let attributes else {
      return nil
    }
    guard let modifiedAttributes = attributes.copy() as? UICollectionViewLayoutAttributes else {
      return attributes
    }

    // Since the collection view is inverted, negative Y gives new messages a subtle upward settle.
    modifiedAttributes.transform = CGAffineTransform(translationX: 0, y: -18)
    modifiedAttributes.alpha = 0.0

    return modifiedAttributes
  }

  private func shouldSuppressSendAnimationAppearingItem(at indexPath: IndexPath) -> Bool {
    let isSuppressedIndexPath = sendAnimationSuppressedIndexPaths.contains(indexPath)

    guard !sendAnimationSuppressedAppearingItems.isEmpty else {
      return isSuppressedIndexPath
    }

    guard let collectionView,
          indexPath.section < collectionView.numberOfSections,
          indexPath.item < collectionView.numberOfItems(inSection: indexPath.section),
          let dataSource = collectionView.dataSource
            as? UICollectionViewDiffableDataSource<MessageListSectionID, MessageListItem>,
          let item = dataSource.itemIdentifier(for: indexPath)
    else {
      return isSuppressedIndexPath
    }

    let isSuppressedItem = sendAnimationSuppressedAppearingItems.contains(item)
    if isSuppressedIndexPath, !isSuppressedItem {
      SendMessageAnimationDiagnostics.debug(
        "layout suppress-indexpath-fallback indexPath=\(indexPath) item=\(item)"
      )
    }
    return isSuppressedItem || isSuppressedIndexPath
  }

  override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes? {
    guard
      let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    else {
      return nil
    }

    attributes.transform = CGAffineTransform(translationX: 0, y: -18)
    attributes.alpha = 0.0
    return attributes
  }

  static func createSectionedLayout(
    sectionIdProvider: @escaping (Int) -> MessageListSectionID? = { _ in nil }
  ) -> UICollectionViewCompositionalLayout {
    let configuration = UICollectionViewCompositionalLayoutConfiguration()
    configuration.scrollDirection = .vertical

    let layout = AnimatedCompositionalLayout(sectionProvider: { sectionIndex, _ in
      // Message item
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(44)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)

      // Group
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(44)
      )
      let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])

      // Section
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = 0
      guard sectionIdProvider(sectionIndex)?.showsDateSeparator != false else {
        return section
      }

      // Footer for date separator (appears at bottom because collection view is inverted)
      let footerSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .absolute(DateSeparatorView.height)
      )
      let footer = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: footerSize,
        elementKind: UICollectionView.elementKindSectionFooter,
        alignment: .bottom
      )
      footer.pinToVisibleBounds = true // This makes it sticky
      section.boundarySupplementaryItems = [footer]

      return section
    }, configuration: configuration)

    return layout
  }

  static func createLayout() -> UICollectionViewCompositionalLayout {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(44)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(44)
    )
    let group = NSCollectionLayoutGroup.vertical(
      layoutSize: groupSize,
      subitems: [item]
    )

    let section = NSCollectionLayoutSection(group: group)

    let layout = AnimatedCompositionalLayout(section: section)
    return layout
  }
}

// final class AnimatedCollectionViewLayout: UICollectionViewFlowLayout {
//  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
//    -> UICollectionViewLayoutAttributes?
//  {
//    guard
//      let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)?.copy()
//      as? UICollectionViewLayoutAttributes
//    else {
//      return nil
//    }
//
//    // Initial state: moved down and slightly scaled
//    attributes.transform = CGAffineTransform(translationX: 0, y: -30)
//    attributes.alpha = 0
//
//    return attributes
//  }
// }

// final class AnimatedCollectionViewCompositionalLayout: UICollectionViewCompositionalLayout {
//  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
//    -> UICollectionViewLayoutAttributes?
//  {
//    guard
//      let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)?.copy()
//      as? UICollectionViewLayoutAttributes
//    else {
//      return nil
//    }
//
//    // Initial state: moved down and slightly scaled
//    attributes.transform = CGAffineTransform(translationX: 0, y: -30)
//    attributes.alpha = 0
//
//    return attributes
//  }
// }

// final class AnimatedCollectionViewCompositionalLayout: UICollectionViewCompositionalLayout {
//  private var appearingIndexPaths: Set<IndexPath> = []
//
//  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) ->
//  UICollectionViewLayoutAttributes? {
//    guard let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) else {
//      return nil
//    }
//
//    // Only animate new messages
//    guard appearingIndexPaths.contains(itemIndexPath) else {
//      return attributes
//    }
//
//    let animatedAttributes = attributes.copy() as! UICollectionViewLayoutAttributes
//
//    animatedAttributes.transform = CGAffineTransform(translationX: 0, y: -30)
//    animatedAttributes.alpha = 0
//
//    return animatedAttributes
//  }
// }
