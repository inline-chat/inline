export const isSingleEmoji = (value: string): boolean =>
  /^(?:\p{Extended_Pictographic}(?:\p{Emoji_Modifier})?(?:\uFE0F|\uFE0E)?(?:\u200D\p{Extended_Pictographic}(?:\p{Emoji_Modifier})?(?:\uFE0F|\uFE0E)?)*|\p{Regional_Indicator}{2}|[#*0-9]\uFE0F?\u20E3)$/u.test(
    value,
  )
