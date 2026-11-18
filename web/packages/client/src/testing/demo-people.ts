import { Member_Role } from "@inline-chat/protocol/core"
import { SeededRandom } from "./rng"

/**
 * The demo account's people: names in several scripts, usernames, generated
 * avatars for some, and the shape of membership (space rosters with roles,
 * public and private threads, direct messages). Pure functions of the seed.
 */

export type DemoUser = {
  id: bigint
  firstName: string
  lastName?: string
  username?: string
  /** A generated avatar (`demoAvatarDataUrl`), seeded by the user. */
  avatar: boolean
  bot?: boolean
}

export type DemoMember = { userId: bigint; role: Member_Role; date: number }

export type DemoSpace = {
  id: bigint
  name: string
  /** Every member, the account's user first. */
  members: DemoMember[]
}

type Name = readonly [native: string, roman: string]

const FIRST: Record<string, readonly Name[]> = {
  latin: [
    ["Ava", "ava"], ["Noah", "noah"], ["Mia", "mia"], ["Liam", "liam"], ["Sofia", "sofia"], ["Lucas", "lucas"],
    ["Elena", "elena"], ["Mateo", "mateo"], ["Zoë", "zoe"], ["Hugo", "hugo"], ["Inès", "ines"], ["Felix", "felix"],
    ["Nora", "nora"], ["Theo", "theo"], ["Clara", "clara"], ["Jonas", "jonas"], ["Maya", "maya"], ["Leo", "leo"],
    ["Anika", "anika"], ["Rafael", "rafael"], ["Priya", "priya"], ["Kwame", "kwame"], ["Aiko", "aiko"], ["Björn", "bjorn"],
  ],
  arabic: [["ليلى", "layla"], ["عمر", "omar"], ["نور", "noor"], ["يوسف", "yusuf"], ["سارة", "sara"], ["كريم", "karim"]],
  hebrew: [["נועה", "noa"], ["איתי", "itai"], ["מאיה", "maya"], ["יונתן", "yonatan"], ["תמר", "tamar"]],
  cjk: [["美咲", "misaki"], ["陽翔", "haruto"], ["さくら", "sakura"], ["伟", "wei"], ["芳", "fang"], ["健太", "kenta"]],
  cyrillic: [["Анна", "anna"], ["Иван", "ivan"], ["Мария", "maria"], ["Дмитрий", "dmitry"], ["Ольга", "olga"]],
}

const LAST: Record<string, readonly Name[]> = {
  latin: [
    ["Chen", "chen"], ["Garcia", "garcia"], ["Müller", "muller"], ["Rossi", "rossi"], ["Kowalski", "kowalski"],
    ["Novak", "novak"], ["Silva", "silva"], ["Johansson", "johansson"], ["Dubois", "dubois"], ["Okafor", "okafor"],
    ["Tanaka", "tanaka"], ["Haddad", "haddad"], ["Park", "park"], ["Moreau", "moreau"], ["Byrne", "byrne"],
    ["Costa", "costa"], ["Larsen", "larsen"], ["Nguyen", "nguyen"], ["Schmidt", "schmidt"], ["O'Brien", "obrien"],
  ],
  arabic: [["حداد", "haddad"], ["منصور", "mansour"], ["خليل", "khalil"], ["سعيد", "saeed"]],
  hebrew: [["כהן", "cohen"], ["לוי", "levi"], ["מזרחי", "mizrahi"], ["פרץ", "peretz"]],
  cjk: [["佐藤", "sato"], ["鈴木", "suzuki"], ["王", "wang"], ["李", "li"], ["高橋", "takahashi"]],
  cyrillic: [["Смирнова", "smirnova"], ["Иванов", "ivanov"], ["Кузнецова", "kuznetsova"], ["Попов", "popov"]],
}

const SCRIPTS = { latin: 64, arabic: 9, hebrew: 9, cjk: 10, cyrillic: 8 }

/** Names, usernames and avatars for the account's users (IDs as the plan has them). */
export const demoUsers = (seed: number, ids: readonly bigint[]): DemoUser[] => {
  const taken = new Set<string>()
  return ids.map((id) => {
    const random = new SeededRandom(seed).fork(`user:${id}`)
    const script = random.weighted(SCRIPTS)
    const [firstName, firstRoman] = random.pick(FIRST[script]!)
    const last = random.bool(0.85) ? random.pick(LAST[script]!) : undefined
    let username: string | undefined
    if (random.bool(0.9)) {
      const base = last ? `${firstRoman}${random.bool(0.5) ? "." : "_"}${last[1]}` : firstRoman
      username = base
      for (let suffix = 2; taken.has(username); suffix += 1) username = `${base}${suffix}`
      taken.add(username)
    }
    return {
      id,
      firstName,
      ...(last ? { lastName: last[0] } : {}),
      ...(username ? { username } : {}),
      avatar: random.bool(0.55),
    }
  })
}

/** A display name, as the clients build it. */
export const demoUserName = (user: Pick<DemoUser, "firstName" | "lastName">) =>
  user.lastName ? `${user.firstName} ${user.lastName}` : user.firstName

/**
 * Space rosters: everyone in a space's threads, plus a few people in no
 * private thread of it (so a mention can name someone outside a thread).
 * The account's user owns the first space and is a member elsewhere; one
 * other member per space is an admin.
 */
export const demoSpaces = (options: {
  seed: number
  selfUserId: bigint
  anchor: number
  spaces: ReadonlyArray<{ id: bigint; name: string }>
  chats: ReadonlyArray<{ spaceId?: bigint; participants: readonly bigint[] }>
  users: ReadonlyArray<{ id: bigint }>
}): DemoSpace[] =>
  options.spaces.map((space, index) => {
    const random = new SeededRandom(options.seed).fork(`space:${space.id}`)
    const ids = new Set<bigint>()
    for (const chat of options.chats) {
      if (chat.spaceId !== space.id) continue
      for (const id of chat.participants) if (id !== options.selfUserId) ids.add(id)
    }
    const outsiders = options.users.filter((user) => !ids.has(user.id) && user.id !== options.selfUserId)
    for (let count = Math.min(outsiders.length, random.int(3, 8)); count > 0; count -= 1) {
      const pick = random.pick(outsiders)
      ids.add(pick.id)
    }
    const others = Array.from(ids).sort((left, right) => (left < right ? -1 : 1))
    const day = 24 * 60 * 60
    const members: DemoMember[] = [
      {
        userId: options.selfUserId,
        role: index === 0 ? Member_Role.OWNER : Member_Role.MEMBER,
        date: options.anchor - 400 * day,
      },
      ...others.map((userId, rank) => ({
        userId,
        role: rank === 0 ? Member_Role.ADMIN : Member_Role.MEMBER,
        date: options.anchor - random.int(5, 380) * day,
      })),
    ]
    return { id: space.id, name: space.name, members }
  })
