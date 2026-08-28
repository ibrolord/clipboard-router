# Clipboard Router pre-polish product audit

Captured from the packaged macOS app on 2026-08-11 at the default product viewport. This audit is the baseline for the Find → Keep → Use → Protect redesign.

## Core flow

1. **Open Library / empty History — Needs restructuring**  
   Evidence: `01-library-and-note.png`  
   Capture status is clear and the native three-pane structure is appropriate. The sidebar mixes core library objects, filters, security, workflows, folders, and sync at equal visual priority. The middle and inspector panes also show two competing empty states.

2. **Browse Saved items — Mostly healthy**  
   Evidence: `02-saved-clip-detail.png`  
   The list hierarchy and provenance are readable. The inspector can remain blank when a collection has items but no selection, and the label “All Saved Clips” is unnecessarily verbose.

3. **Inspect and reuse a saved note — Critical layout issue**  
   Evidence: `03-selected-note-detail.png`  
   Too many header actions collapse the title and controls into fragments. AI, app routing, organization, sharing, transformations, and workflow commands repeat across the header, action section, footer, and menus. The basic reuse action is buried.

4. **Ask about an item — Needs hierarchy polish**  
   Evidence: `04-ai-assistant.png`  
   The source attachment and explicit Send boundary are strong. The engine selector wraps, the conversation does not use the available width, the composer lacks a clear prompt affordance, and task names such as “Enrich” are ambiguous.

5. **Recall an item through Insert Palette — Critical empty-state issue**  
   Evidence: `05-insert-palette.png`  
   Alias administration dominates what should be a retrieval-first surface. An empty query only offers pinned or aliased items, so a library with a recent ordinary saved note can incorrectly appear empty.

6. **Navigate the expanded sidebar — Critical information overload**  
   Evidence: `06-workflows.png`  
   This image records the sidebar after scrolling rather than a confirmed Workflows dashboard. It demonstrates that folders and utilities fall below a long inventory of filters, while the selected-item footer adds another action hierarchy.

## Panel synthesis

The redesign organizes the product around four jobs:

- **Find:** History, search, Quick Paste, and compact browse filters.
- **Keep:** Saved items, notes, pins, folders, tags, sharing, and export.
- **Use:** Copy, paste, contextual actions, Assistant, app routing, and automations.
- **Protect:** Sensitive review, Vault, Private Session, excluded apps, and explicit sync state.

## Acceptance checks

- Library, Saved, Notes, Pinned, and Folders remain visible without scrolling at the default window size.
- Sync remains visible as product state, without competing with everyday Library destinations.
- Selected-item headers expose no more than three visible controls and no label truncates at the minimum window size.
- Every existing organization and protection command remains reachable through a coherent More menu.
- Quick Paste shows pinned and recent eligible saved items for an empty query, distinguishes an empty library from no matches, and never passively monitors system typing.
- Assistant never sends until the user chooses Send; hosted mode continues to disclose what leaves the Mac.
- Vault, Private Session, sensitive, secret-like, location-bearing, file, and rich-media items remain excluded from Assistant and Quick Paste.
- Menu-bar search, copy, paste, folder move, pin, Vault, share, and note actions remain available without opening the Library.
- The active system clipboard is not changed by sync, search, hover, Assistant presentation, or other passive UI events.

## Evidence limits

Static screenshots do not prove keyboard order, VoiceOver announcements, live resize behavior, paste-target revalidation, Vault authentication, or CloudKit account state. Those require a fresh packaged build and interaction verification after implementation.
