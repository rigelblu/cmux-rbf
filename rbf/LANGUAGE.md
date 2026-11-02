---
title: Team Language
subtitle: Every community has its own code. You must know what each one values — Larry McEnerney
rules: |
  - Specify words this project and its users (human and agents) use that's specific to this project, team, and its domain.
---

**Use skill:** `how-you-write-team`

# 🔵⋯ Figma panes (`#cm-73`)
## 🟠⋯ What the agent points at
"Board" did two jobs: one design screen, and whatever `cmux figma goto` points at. *"before your agent has named a board"* cost Tom a question on 2026-10-20 — *"when you said board, I guess you mean node?"*. Each job now has its own word.

- **Board** — a top-level frame in a Figma Design file: one screen of a design, like "Library" or "Add book". What the agent draws and lays out, and what `cmux figma fit` centers. Every board already has a name, so never say a board needs naming. *"three boards centered", "the agent re-laid the boards"*
- **Node** — anything in a Figma file that has an id: a page, a board, a group, a layer. `cmux figma goto <node-id>` takes any node id; the agent usually points at a board, and `0-1` is the file's first page. The agent **points at** a node by its id — not "names" it. *"goto node 12-2", "with no node pointed at yet, the preview shows node 0-1, the first page"*

## 🟠⋯ The two sides of a Figma pane (`#cm-73.3`)
The pane holds two pages and shows one at a time. *"Canvas"* named the second until 2026-10-21, when Tom picked **Editor** — *"what do you think of renaming 'Canvas' to 'Figma Canvas' or 'Figma Editor'"* — because cmux already has **Toggle Canvas Layout** (`⌃⌘C`), a different feature, and the pencil icon says edit.

- **Preview** — cmux's own page framing Figma's embed of one node, with Figma's controls hidden. Where the agent's `cmux figma goto` takes you. *"the preview shows the agent's board"*
- **Editor** — Figma's full editor on the file, where Tom works. Not *canvas* for this side: canvas is cmux's Canvas Layout, and inside Figma it is only the drawing area of the editor. *"switch to the editor", "the editor keeps your zoom and selection"*
- **Switch** — moving the pane from one side to the other (`⌥⇧⌘C`, the palette, or the hover-row control). Never *flip*: that is Design Focus's flip of the pair. *"Figma: Switch Preview and Editor"*

# 🔵⋯ The Agent Pane (`#cm-126.3`)
- **Agent Pane** — the pane beside one agent that is its interface to Tom, showing its updates in any medium (a Figma board inside the agent's page, a Claude artifact, a web page); opened and steered by `cmux agent-pane show`, its tab captioned "Agent Pane"; it belongs to the agent's terminal. Not the agent's own terminal pane, not the Figma pane `cmux figma open` makes, and not upstream's Agent Chat (Tom's naming decision, 2026-11-01, which replaced "agent reader"). *"the agent's Agent Pane opened beside it", "show it in your Agent Pane"*
