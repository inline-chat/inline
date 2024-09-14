export const DATABASE_URL = process.env.DATABASE_URL as string

if (!DATABASE_URL) {
  throw new Error("DATABASE_URL env variable must be defined.")
}
