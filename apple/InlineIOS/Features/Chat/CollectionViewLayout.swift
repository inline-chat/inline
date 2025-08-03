import InlineKit
import UIKit

final class AnimatedCompositionalLayout: UICollectionViewCompositionalLayout {
  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    guard let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) else {
      return nil
    }

    let modifiedAttributes = attributes.copy() as! UICollectionViewLayoutAttributes

    // For new items appearing, start them from below and transparent
    // Since collection view is inverted, negative Y makes items slide up from bottom (proper chat behavior)
    modifiedAttributes.transform = CGAffineTransform(translationX: 0, y: -50)
    modifiedAttributes.alpha = 0.0

    return modifiedAttributes
  }

  override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    guard
      let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    else {
      return nil
    }

    attributes.transform = CGAffineTransform(translationX: 0, y: -26)
    attributes.alpha = 0.0
    return attributes
  }

  static func createSectionedLayout() -> UICollectionViewCompositionalLayout {
    let configuration = UICollectionViewCompositionalLayoutConfiguration()
    configuration.scrollDirection = .vertical

    let layout = AnimatedCompositionalLayout(sectionProvider: { _, _ in
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
