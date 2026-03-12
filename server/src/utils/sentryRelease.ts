const SERVER_SENTRY_RELEASE_PREFIX = "inline-server"

export function buildServerSentryRelease(version: string, gitCommitSha: string): string {
  return gitCommitSha !== "N/A"
    ? `${SERVER_SENTRY_RELEASE_PREFIX}@${version}+${gitCommitSha}`
    : `${SERVER_SENTRY_RELEASE_PREFIX}@${version}`
}

export function buildServerSentryDist(gitCommitSha: string): string | undefined {
  return gitCommitSha !== "N/A" ? gitCommitSha : undefined
}
