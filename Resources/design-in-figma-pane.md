---
name: design-in-figma-pane
description: Put a design from this conversation into a new Figma file in the person's cmux Figma folder, or start a new design there, and show it in a cmux Figma pane. Run only when the person types /design-in-figma-pane or $design-in-figma-pane, or picks "Put Design into Figma" or "New Design in Figma" in cmux's Figma button menu.
disable-model-invocation: true
---
<!-- cmux-managed-skill: design-in-figma-pane. cmux rewrites this file at every launch. Delete this line to keep your own copy. -->

# Design in a cmux Figma pane

The word after the command says which job:
- `put`: put the latest design in this conversation into Figma
- `new`: design in Figma from the start

With no word, or any other word, ask "new or put?" and do nothing else until the person answers.

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

## 4. Draw the design in that file
Draw it with your Figma MCP tools in the file you just made, by its file key. Draw in no other file.

## 5. Show it
Run `cmux figma open '<the new file's link>'`.
