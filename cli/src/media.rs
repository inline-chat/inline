use crate::protocol::proto;

pub(crate) fn best_photo_size(
    photo: &proto::Photo,
) -> (Option<String>, Option<i32>, Option<i32>, Option<i32>) {
    let mut best: Option<(&proto::PhotoSize, i64)> = None;
    for size in &photo.sizes {
        if size.cdn_url.is_none() {
            continue;
        }
        let area = size.w as i64 * size.h as i64;
        if best.is_none_or(|(_, best_area)| area > best_area) {
            best = Some((size, area));
        }
    }
    if let Some((size, _)) = best {
        return (
            size.cdn_url.clone(),
            Some(size.size),
            Some(size.w),
            Some(size.h),
        );
    }
    (None, None, None, None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn best_photo_size_picks_largest_size_with_url() {
        let photo = proto::Photo {
            sizes: vec![
                proto::PhotoSize {
                    w: 20,
                    h: 20,
                    size: 100,
                    cdn_url: Some("small".to_string()),
                    ..Default::default()
                },
                proto::PhotoSize {
                    w: 200,
                    h: 200,
                    size: 500,
                    cdn_url: None,
                    ..Default::default()
                },
                proto::PhotoSize {
                    w: 50,
                    h: 50,
                    size: 200,
                    cdn_url: Some("large".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        assert_eq!(
            best_photo_size(&photo),
            (Some("large".to_string()), Some(200), Some(50), Some(50))
        );
    }
}
