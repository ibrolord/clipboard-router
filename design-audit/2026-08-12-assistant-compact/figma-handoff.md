# Clipboard Router Compact Assistant — Figma handoff

Target file: <https://www.figma.com/design/7pHpzi6kui7wVjVVtghIlv>

## Scope

- Compact idle state at 560 × 201 px.
- Preset-selected state with all six purposes visible.
- Progressive response state with Copy, Save to Notes, and follow-up composer.
- Before/after comparison and interaction annotations.

## Source mapping

- SwiftUI source: `Sources/ClipboardRouterApp/AdvancedActionViews.swift`
- Root view: `AIClipAssistantSheet`
- Prompt preservation: `AssistantPromptTemplatePolicy`
- Typography: macOS semantic styles rendered with SF Pro.
- Layout: 14 px outer padding, 8 px vertical rhythm, 10 px composer/response corner radius.

## Required behavior

1. Opening Assistant does not send, mutate, or show an empty conversation card.
2. Preset selection never closes the sheet.
3. Switching presets replaces the prior untouched template.
4. A custom or edited prompt is preserved when a preset changes.
5. Send becomes disabled synchronously when a request starts.
6. Conversation appears only while working or after a message exists.
7. Cloud and on-device disclosures are visible before sending.
8. Responses are inert drafts; Copy and Save to Notes require direct user actions.

## Figma placement plan

Create one 1800 px-wide board with three equal state cards and a lower interaction-contract row:

1. Before — `01-before.png`
2. Compact idle — `02-compact-open.jpg`
3. Preset selected — `03-compact-research.jpg`
4. Response and follow-up — editable wireframe from `figma-board.html`

The connected Apple `macOS 26` library should supply segmented controls, buttons, text fields, system colors, and materials when the Figma MCP quota permits asset search. Until then, preserve the SwiftUI semantic mapping rather than substituting Material components.

