# Contributing to Clipboard Router

Thanks for helping improve Clipboard Router. Focused bug fixes, tests,
accessibility improvements, documentation corrections, and carefully scoped
features are welcome.

## Before opening a pull request

1. Open or reference an issue for behavior changes so the user outcome and
   privacy boundary are clear before implementation.
2. Keep clipboard contents, API keys, signing identities, provisioning
   profiles, and other credentials out of issues, fixtures, logs, screenshots,
   commits, and pull requests.
3. Preserve the product's explicit-review boundary: routing may prepare content
   and open a destination, but must not silently submit it.
4. Add tests for changed behavior and run the source verifier:

   ```bash
   ./Scripts/verify_source.sh
   ```

5. Run a secret scan over the changes before pushing when `gitleaks` is
   available:

   ```bash
   gitleaks git --redact --no-banner
   ```

## Pull requests

- Use a clear present-tense title.
- Explain the user-visible behavior and the privacy or security impact.
- Include the exact test commands you ran.
- Keep generated build output, signed applications, archives, credentials, and
  personal clipboard data out of the repository.
- Treat screenshots as public. Use isolated fictional fixtures rather than a
  real clipboard or desktop capture.

By contributing, you agree that your contributions are licensed under the MIT
License used by this repository.
