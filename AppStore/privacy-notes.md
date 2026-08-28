# App Privacy preparation notes

These notes are preparation evidence, not final legal advice or a submitted App
Privacy questionnaire.

## Baseline behavior represented by the listing

- The local workspace does not require an account.
- Clipboard history, saved clips, notes, folders, Private Session, Sensitive
  Review, and Vault are local app functionality.
- Private Session clips stay in memory.
- Vault clips are encrypted and authentication-gated.
- The app does not automatically submit content through a handoff.
- Contacts, Calendar, and Location access are requested only for an explicit
  user-selected action.
- The repository states that it has no analytics transport.

## Required questionnaire reconciliation

`Resources/PrivacyInfo.xcprivacy` declares
`NSPrivacyCollectedDataTypeOtherUserContent` for app functionality, with the
data linked to the user and not used for tracking. This matches the conservative
App Store Connect disclosure for optional, user-initiated sends to a configured
AI or CRM provider; local-only clipboard content is not transmitted by default.

Before submission, the publisher must determine whether the exact Mac App Store
build transmits clipboard content through optional iCloud sync, a user-configured
AI provider, crash reporting, licensing, support, or any other service. Then the
privacy manifest, public privacy policy, in-app disclosures, and App Store
Connect answers must all describe the same shipped behavior.

Do not select **Data Not Collected** merely because the core workspace is local
until every optional network path in the exact submitted build has been audited.

## Required-reason API declaration already present

The manifest declares UserDefaults access with reason code `CA92.1`. Revalidate
the reason against the exact binary and current Apple documentation before
submission.
