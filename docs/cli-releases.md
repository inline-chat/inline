# CLI release authentication

The CLI Release workflow publishes GitHub/R2 artifacts and updates the separate
`inline-chat/homebrew-inline` repository. Homebrew publishing uses the dedicated
`INLINE_HOMEBREW_DEPLOY_KEY` Actions secret in `inline-chat/inline`.

The public Ed25519 key is registered as a write-enabled deploy key only on the
Homebrew repository. The private key goes into an isolated SSH agent through
stdin; the workflow never writes it to a key file. SSH ignores personal config,
uses only that identity, and pins GitHub's published Ed25519 host key. The agent
is stopped after the operation. No personal GitHub token is copied into CI.

Stable releases that update Homebrew verify SSH write authentication before
building, using a push dry run that does not change repository contents. The
same authentication script is reused during publication. It lives in the
workflow so releasing an older source ref does not require a new helper file.

To check credentials without building or publishing:

```sh
gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f ref=main -f preflight_only=true
```

Wait for the preflight job to succeed. Validation, build, and publication jobs
must be skipped. For full stable credentials, leave `targets` empty and
`build_only` false. No new release or version bump is needed for this check.

Deploy keys do not expire automatically. To rotate, register a new dedicated
key, replace `INLINE_HOMEBREW_DEPLOY_KEY`, and run the preflight check before
revoking the previous key. GitHub may also remove a deploy key when the GitHub
authorization used to create it is revoked. Never paste private keys into logs,
commit them, or reuse a developer's general-purpose SSH key.

The former `INLINE_HOMEBREW_TAP_TOKEN` secret is no longer used by this workflow.
Its presence does not imply it is still valid; do not reuse it as a fallback.

References: [GitHub deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
and [host-key fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
