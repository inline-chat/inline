const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
const maxDigit = alphabet.length - 1
const maxLength = 128

const digitMap = new Map([...alphabet].map((char, index) => [char, index]))

export const FractionalIndex = {
  between,
  before,
  after,
  sequence,
  isValid,
}

function between(left?: string | null, right?: string | null): string {
  if (left != null && right != null && left >= right) {
    throw new Error("left fractional index must be lower than right")
  }

  let prefix = ""
  let position = 0

  while (true) {
    const leftDigit = digitAt(left, position, 0)
    const rightDigit = digitAt(right, position, maxDigit)

    if (rightDigit - leftDigit > 1) {
      const digit = Math.floor((leftDigit + rightDigit) / 2)
      return prefix + alphabet[digit]
    }

    prefix += alphabet[leftDigit]
    position += 1
  }
}

function before(first?: string | null): string {
  return between(null, first)
}

function after(last?: string | null): string {
  return between(last, null)
}

function sequence(count: number): string[] {
  const result: string[] = []
  let previous: string | null = null

  for (let index = 0; index < count; index += 1) {
    previous = after(previous)
    result.push(previous)
  }

  return result
}

function isValid(value: string): boolean {
  if (value.length === 0 || value.length > maxLength) {
    return false
  }

  for (const char of value) {
    if (!digitMap.has(char)) {
      return false
    }
  }

  return true
}

function digitAt(value: string | null | undefined, position: number, fallback: number): number {
  if (value == null || position >= value.length) {
    return fallback
  }

  const char = value[position]
  if (char == null) {
    return fallback
  }

  const digit = digitMap.get(char)
  if (digit == null) {
    throw new Error(`invalid fractional index character: ${char}`)
  }

  return digit
}
