export const filterFalsy = <T>(n?: T | false): n is T => Boolean(n)
