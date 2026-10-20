---
name: design-in-figma-pane
description: Put a design from this conversation into a new Figma file in the person's cmux Figma folder, start a new design there, or re-lay the boards of the Figma file you opened, and show it in a cmux Figma pane. Run only when the person types /design-in-figma-pane or $design-in-figma-pane, picks "Put Design into Figma" or "New Design in Figma" in cmux's Figma button menu, or cmux types it after the person flips Figma or picks a board layout in Design Focus.
disable-model-invocation: true
---
<!-- cmux-managed-skill: design-in-figma-pane. cmux rewrites this file at every launch. Delete this line to keep your own copy. -->

# Design in a cmux Figma pane

The words after the command say which job:
- `put`: put the latest design in this conversation into Figma
- `new`: design in Figma from the start
- `layout vertical` or `layout horizontal`: re-lay the boards of the Figma file you last opened in this conversation (see "Re-lay the boards")

With no word, or any other word, ask "new or put?" and do nothing else until the person answers. `layout` with no second word, or with a second word other than `vertical` or `horizontal`, counts as any other word.

## 1. Know what to draw
- `put`: take the latest design in this conversation: a sketch, a wireframe, or a screen described in words. If there is none, say so and stop. Make no file.
- `new`: design what this conversation is about. If that isn't clear, ask what to design, and wait for the answer.

## 2. Find the folder
Run `cmux figma folder`.
- It prints `projectId` and `planKey`: go on.
- It prints "No default Figma folder": make no file, in Drafts or anywhere. Ask the person to choose a folder from cmux's Figma button menu, "Choose Figma Folder…", or with `cmux figma folder set '<folder-url>'`. Then stop.
- It exits with an error: show its message and stop.

## 3. Make a new file
With your Figma MCP tools, create a new Figma Design file, passing `planKey` and `projectId` exactly as printed. Name it after the design. Always a new file: never draw in a file that is already open. If you have no Figma MCP tools, or Figma says you are signed out, say so and stop. If creating the file fails in any other way, show the error and stop. Never retry without `projectId`: that makes the file in Drafts.

## 4. Show it
Run `cmux figma open '<the new file's link>'`. Its answer ends with `orientation=vertical` or `orientation=horizontal`: the shape of the pane the file landed in. If the answer has no `orientation=`, take `vertical`.

## 5. Draw the design in that file
Draw it with your Figma MCP tools in the file you just made, by its file key. Draw in no other file. Lay its boards out for the orientation step 4 gave: `vertical`, one column, top to bottom; `horizontal`, one row, left to right. Then run `cmux figma fit --surface <the surface cmux figma open printed>`. If it fails, say so in one line and stop; switch or focus nothing.

## Re-lay the boards
For `layout vertical` and `layout horizontal` only; steps 1 to 5 don't apply.
- Take the Figma file you last opened in this conversation with `cmux figma open`. If you opened none, say so and stop.
- With your Figma MCP tools, move that file's top-level boards into one column, top to bottom (`vertical`), or one row, left to right (`horizontal`), keeping their order. Leave the first board where it is and line the rest up after it. Change nothing inside a board, add nothing, delete nothing, and make no new file. Then run `cmux figma fit --surface <the surface cmux figma open printed>`. If it fails, say so in one line and stop; switch or focus nothing.
- If you have no Figma MCP tools, or Figma says you are signed out, say so and stop.
