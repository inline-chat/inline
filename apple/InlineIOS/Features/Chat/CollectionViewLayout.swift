import InlineKit
import UIKit

final class AnimatedCompositionalLayout: UICollectionViewCompositionalLayout {
  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
    attributes?.transform = CGAffineTransform(scaleX: 0.5, y: -0.5)
    attributes?.alpha = 0
    return attributes
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
