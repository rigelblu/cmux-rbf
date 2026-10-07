# Workspace Groups

Workspace groups let you gather workspaces into collapsible named groups in the sidebar, and put one group inside another. Each group has an anchor, a customizable `+` button for spawning new workspaces inside it, and right-click actions for renaming, pinning, moving, ungrouping, and editing its configuration.

## Concepts

### Anchor

Every group has one **anchor**: the workspace behind the group's name. The group header in the sidebar IS the anchor's row — there is no separate row for it. Clicking the header name focuses the anchor's panels. Clicking the chevron collapses or expands the group. (The CLI, the JSON and `cmux.json` all say "anchor".)

A group's anchor is always a brand new workspace at creation time; grouping a selection or `create` never promotes one of your existing workspaces into the anchor. The anchor's working directory is inherited from the first selected workspace (when grouping a selection) or from the active workspace (when creating via the CLI without `--cwd`).

Closing the anchor closes only that workspace and **promotes the next workspace directly in the group to be the new anchor**, so the group and its other workspaces stay (the promoted workspace then shows the group name as the header). If the anchor was the last workspace directly in the group, what happens next depends on the group:

- A group that is not pinned and holds no other group is removed.
- A pinned group stays, as an empty header.
- A group that holds other groups stays, with no anchor (see [A group with no anchor](#a-group-with-no-anchor)).

To flatten a group back into ungrouped workspaces, use **Ungroup Workspaces**; to close every workspace in a group, use **Delete Group**.

### Groups inside groups

A group can sit inside another group, to any depth. The group it sits in is its **parent** and the groups it holds are its **children**. cmux gives no depth a meaning: a parent is not a "project" and a child is not a "task", they are both groups. A group inside another keeps its own anchor, name, color, icon and pin.

Two words used below. A group's **rows** are the workspaces and groups directly in it, not the ones inside its children. The sidebar has rows too: the workspaces and groups that are in no group. A row's **depth** is how many groups hold it; a row in no group has depth 0.

A group is never inside itself or inside a group it holds. Moving a group takes everything inside it along. Moving a group creates, closes and replaces no workspace, and the selected workspace stays selected.

#### Move Group to

Right-click a group's header and choose **Move Group to**. The submenu lists:

- **Top Level**, which takes the group out of every group and puts it in the sidebar itself.
- Every other group in the window, indented by depth, except the group itself and the groups inside it.

The group's current place has a checkmark; choosing it changes nothing. With no other group in the window, the submenu holds only **Top Level**.

Where the group lands:

- Inside a group, it becomes the last of that group's pinned rows if it is pinned, otherwise the last of its unpinned rows.
- In the sidebar, an unpinned group lands directly below the row it came out of (the outermost group that held it). A pinned group lands at the end of the pinned rows. An unpinned group that comes out of a pinned row lands first among the unpinned rows, since an unpinned row cannot sit among pinned ones. A group with no workspace anywhere inside it follows the rule in [Empty groups](#empty-groups) instead.
- If you move a group back to where it came from, its place among that group's rows can differ from where it sat before.
- If the group you choose is collapsed, the moved group is hidden inside it. The group expands only if the moved group holds the selected workspace.

**Move Group to** has no keyboard shortcut. A group can be put inside another only from this menu; dragging a header does not do it (see [Dragging](#dragging)). A group, at any depth, cannot be moved to another window.

#### The rows of a group

A group's rows read, top to bottom: its anchor (the header itself), its pinned rows, then its unpinned rows. Workspaces and child groups share one order within the pinned rows and within the unpinned rows, as they do in the sidebar, and a row stays where you put it. So a workspace directly in the group can come below a child group's rows; the indent tells them apart.

Each depth indents a row 12 pt more. The indent never takes more than 40% of the sidebar's width, so a name keeps room at any width; rows deeper than that are drawn at the same indent. A name is cut at its end when room runs out, so two names that differ only at their end can read the same when cut.

Collapsing a group hides every row inside it, at every depth. A child group remembers whether it was collapsed. Selecting a hidden workspace — from a notification, the CLI, or next and previous workspace — expands every group above it. If a collapse with the chevron hides the selected workspace, the group's anchor becomes selected instead; a group with no anchor leaves the selection where it is. Collapsing from the CLI never changes the selection.

Only workspace rows on screen carry a number. A group header carries none, and collapsing a group at any depth removes the numbers of the rows inside it, so the rows below renumber.

A collapsed parent shows the unread count of every workspace inside it, at every depth.

#### A group with no anchor

A group has no anchor when you close the last workspace directly in it while it still holds other groups. Its header stays:

- It draws a dot in the group's color where the icon was, grey when the group has no color, whatever icon the group has, and it never looks selected.
- Clicking its name collapses or expands it, since there is no anchor to open. This holds in every window, also for a pinned group with nothing in it.
- The first workspace that joins it — added with `+` or **New Workspace in Group**, or put there with **Move to Group** or a drop — becomes its anchor.
- cmux never removes it automatically. After its last child group leaves, it stays as an empty header until **Ungroup Workspaces** or **Delete Group** removes it. **Ungroup Workspaces** is not offered on a pinned group with nothing in it; use **Delete Group**.
- It stays after you quit and reopen cmux, pinned or not.
- If its anchor's workspace moves to another window, the group stays with its child groups, and the next workspace directly in it becomes the anchor, or it has no anchor. A group that holds no other group is removed if it is not pinned, and its workspaces go up to the group that held it (or into the sidebar); a pinned one keeps its header.

#### Empty groups

A group with no workspace anywhere inside it is an empty group. It cannot sit between two workspaces of its own pin state. cmux puts it just above the next group with the same pin state, in the same group (or the sidebar), that has a workspace inside it; if there is none, below every other row of that pin state there. This holds whatever moved it or emptied it: **Move Group to**, **Unpin Group**, closing its last workspace.

#### Ungroup Workspaces and Delete Group on a parent

- **Ungroup Workspaces** removes only the parent's header and moves its workspaces and child groups up one group (or into the sidebar). Nothing closes, and the child groups stay intact. Unpinned rows keep their place and order; pinned rows join the pinned rows where they arrive. When the ungrouped parent was itself pinned, its unpinned rows land together, in order, first among the unpinned rows where they arrive.
- **Delete Group** closes every workspace inside the parent, at every depth, the anchor of each group included, and removes the parent and every group inside it. It asks first, and the question names the group, how many groups are inside it and how many workspaces will close. **Cancel** changes nothing. A workspace that joins the group while the question is open is not closed, and one that something else moves out of the group meanwhile is not closed either.

**Delete Group** asks before it closes anything when the group is pinned, holds a workspace besides its anchor, or holds another group.

#### Other commands on workspaces and groups inside groups

- **Remove from Group** takes a workspace out of its group and into the group that holds that one (or into the sidebar), directly below the group it left. A pinned workspace lands among the pinned rows there. An unpinned workspace that leaves a pinned group lands first among the unpinned rows there.
- **Move to Top** puts a workspace first among the rows of its pin state in its group, and moves each group above it to the top of its pin state in whatever holds that group.
- With **Reorder on Notification** on (the default), a notification moves each group above the workspace, starting from the outermost, to the first unpinned place in whatever holds it. It stops at the first pinned group: that group and everything inside it stay where they are. If no group above the workspace is pinned, the workspace goes first among the rows of its pin state in its group.
- In a window that holds a group inside another, **Move Up** and **Move Down** move a workspace one row among the rows next to it with the same pin state, a child group counting as one row. They never move a workspace into or out of a group.
- **Mark All Workspaces in Group as Read** and **as Unread** reach every workspace inside the group, at every depth, but not the group's own anchor. The other three commands on the header — **Mark Group as Read**, **Mark Group as Unread** and **Clear Latest Notifications** — act on the group's anchor only. On a group with no anchor, the two **Mark All** commands work and the other three are unavailable.
- A workspace inside any group is not sorted into a color group. Color groups hold only workspaces that are in no group.
- A workspace's **Move to Group** submenu indents groups by depth.

#### Dragging

- A workspace dropped at the edge of a group joins the innermost group on the right half of the sidebar, and leaves it on the left half. On the left half it lands outside the outermost group that ends at that edge. When a child group's last row is also its parent's last row, both end at the same edge, so the left half leaves both. A workspace that leaves a group lands directly below it, or first among the unpinned rows when the group is pinned and the workspace is not.
- Dragging several selected workspaces puts them all in the one place the drop names.
- A group header inside another group drags among the rows of its parent only, within its pin state. Anywhere else no drop line shows. Several selected headers move together only when they share a parent.
- A group with no anchor can be dragged only before or after a group beside it (in the same parent), never between two workspaces.
- Dragging a header never puts a group inside another group. Use **Move Group to**.

#### An example

```
v Work                 the header; Work's anchor is behind the name
   v Backend           a group inside Work
      1 api server
      2 worker
   3 notes
4 scratch              in no group
```

- Right-click `Backend` and choose **Move Group to** ▸ **Top Level**. `Backend` leaves `Work` and lands directly below it, with `api server` and `worker` still inside it.
- **Ungroup Workspaces** on `Work` removes the `Work` header and moves `Backend`, `notes` and Work's former anchor up into the sidebar. Nothing closes.
- **Delete Group** on `Work` asks: *Delete the group “Work”, the group inside it, and close their 5 workspaces?* The five are `api server`, `worker`, `notes`, and the anchors of `Work` and `Backend`.

### Group identity

A group has a `name`, `iconSymbol` (an SF Symbol, default `folder.fill`), and an optional `customColor` (hex string). Automation can also provide an `external_id` (or `idempotency_key`) as a caller-owned identity scoped to the window. Repeating `workspace.group.create` with that identity returns the existing group instead of creating another anchor. Names are not identities: users may have multiple groups with the same name.

The current anchor carries explicit provenance. Only an anchor created by cmux can be removed through the guarded anchor-cleanup option; a user-selected or promoted anchor is never inferred to be disposable.

### Pinning

Groups can be pinned independently of individual workspace pins. In the sidebar and inside every group, pinned rows — workspaces and groups — stay above unpinned rows, and within each pin state the rows keep the order you drag them into.

A pinned group inside another group joins that parent's pinned rows, after the ones already pinned, above the parent's unpinned rows. It does not go to the top of the sidebar: pinning a child never moves its parent, and a collapsed parent hides its pinned child with its other rows. **Unpin Group** leaves the group in the same parent, first among the parent's unpinned rows, unless the group is empty (see [Empty groups](#empty-groups)), which that rule places.

The layout, top to bottom, in the sidebar and inside every group:
1. Pinned rows (workspaces and groups).
2. Unpinned rows (workspaces and groups).

## Creating a group

### From the keyboard (`⌃⌘G` or `⌘⇧G`)

Press `⌃⌘G` to create a new empty workspace group. cmux inserts a fresh anchor as the group header and auto-names it `Group 1`, `Group 2`, … (rename anytime via the header context menu). `⌃⌘G` always makes the group in the sidebar, outside every group.

Select two or more workspaces in the sidebar, press `⌘⇧G`. A fresh anchor is inserted above the selection; all selected workspaces join the group. The group is auto-named `Group 1`, `Group 2`, … (rename anytime via the header context menu). If the topmost selected workspace that is not another group's anchor sits inside a group, the new group is made inside that group, where that workspace was, instead of in the sidebar. `⌘⇧G` collides with React Grab's default; the group handler only consumes the chord when there is an explicit sidebar multi-selection of at least two workspaces, so React Grab still fires in single-selection and browser/terminal contexts. Rebind in Settings → Keyboard if you'd rather the two not share a key.

Single-tab groups are not created from the shortcut. Use the workspace context menu's **New Group from Workspace** entry for that.

### From a workspace context menu

Right-click any workspace in the sidebar, choose **New Empty Workspace Group** for an anchor-only group, **New Group from Workspace** for a group containing that workspace, or **New Group from Selection** when multiple workspaces are selected. The blank area below the sidebar list also offers **New Empty Workspace Group**. Same auto-naming behavior as the shortcuts. **New Group from Workspace** and **New Group from Selection** follow the same rule as `⌘⇧G`: a group made from workspaces that sit inside a group is made inside that group. **New Empty Workspace Group** makes a group in the sidebar.

### From the group header context menu

Right-click an existing group's header for:

- **New Workspace in Group**
- **Rename Group…**
- **Group Color**
- **Pin Group** / **Unpin Group**
- **Move Group to** (see [Groups inside groups](#groups-inside-groups))
- **Mark Group as Read**, **Mark Group as Unread** and **Clear Latest Notifications**, which act on the group's anchor
- **Mark All Workspaces in Group as Read** and **as Unread**, which act on every workspace inside the group, not on its anchor
- **Edit Group Config…** (opens `~/.config/cmux/cmux.json`)
- **Open Workspace Groups Docs**
- **Ungroup Workspaces**, offered on a pinned group only while it holds something
- **Delete Group**

**Group Color** is the same palette a workspace offers, semantic labels included, and it sets the group's own `customColor`. **No Color** clears that override — which returns the header to the neutral band *unless* `cmux.json` resolves a color for the anchor's cwd, in which case the configured color shows through. The checkmark always tracks the group's own color, never a color it inherited from config, so a ticked **No Color** beside a colored band means “the color is coming from your config, not from you”. Ungroup Workspaces keeps the workspaces and removes only the group container. Delete Group closes the group's anchor and every workspace inside the group, at every depth; it asks for confirmation first when the group is pinned, holds a workspace besides its anchor, or holds another group, and the question counts every workspace that closes.

### From the `+` button on a group header

Hover over a group header to reveal a trailing `+` button. Click to create a new workspace in the group at the anchor's cwd. Right-click for **New Workspace in Group**, **Edit Group Config…**, and **Open Workspace Groups Docs**.

Pressing `⌘N` while the active workspace is a group anchor or group member also creates the workspace inside that group. The default group placement is **After current**: from a regular group member, the new workspace lands right after the active member; from the anchor/header, it lands at the top of the group.

## CLI

All group operations are scriptable via `cmux workspace-group <subcommand>`. The hyphenated form ships first; once the broader `cmux workspace <noun>` namespace lands, `cmux workspace group ...` will be the canonical form with the hyphenated form kept as an alias forever.

### Subcommands

```bash
cmux workspace-group list [--json]
cmux workspace-group create --name "manaflow" [--cwd ~/projects/manaflow] [--from <id>,<id>] [--idempotency-key <key>]
cmux workspace-group ungroup <group-id> [--remove-generated-anchor]
cmux workspace-group delete <group-id>                         # dissolve; keep workspaces
cmux workspace-group delete <group-id> --close-workspaces      # explicitly destructive
cmux workspace-group rename <group-id> --name "new name"
cmux workspace-group collapse <group-id>
cmux workspace-group expand <group-id>
cmux workspace-group pin <group-id>
cmux workspace-group unpin <group-id>
cmux workspace-group add --group <group-id> --workspace <workspace-id>
cmux workspace-group remove --workspace <workspace-id>
cmux workspace-group set-anchor --group <group-id> --workspace <workspace-id>
cmux workspace-group new-workspace <group-id> [--placement afterCurrent|top|end]
cmux workspace-group set-color <group-id> [--hex #RRGGBB]
cmux workspace-group set-icon <group-id> [--symbol <sf-symbol>]
cmux workspace-group move <group-id> --to-index <n> | --before <group-id> | --after <group-id>
cmux workspace-group focus <group-id>
```

`create` returns a group handle (`workspace_group:N` by default). Omitting `--from` creates an anchor-only group; existing workspaces are never inferred from selection or caller context. Pass `--json` for the full structured payload.

Use a stable `--idempotency-key` (or `--external-id`) when more than one controller can reconcile the same logical group. The key is atomic within the target window and is persisted with the group. `--remove-generated-anchor` is an explicit cleanup path for an anchor-only group whose current anchor still has cmux-generated provenance; it refuses groups with child workspaces or user-selected anchors.

`delete` dissolves the group and keeps its workspaces by default. Pass `--close-workspaces` only when you intend to close every workspace in the group and terminate its processes. On a group that holds groups, it also closes every workspace inside them, at every depth, and removes those groups. The response reports whether the group was dissolved or its workspaces were closed, including the affected count.

### Groups inside groups, from the CLI

The CLI has no command to put a group inside another group yet; use **Move Group to** in the sidebar. The commands above work on a group that sits inside another group, by its id or ref. What changes on a group that holds groups, or that sits in one:

- `list --json` names the group that holds each group in `parent_group_id`, which is a group id, or `null` when the group is in the sidebar. A parent is listed before its children, in sidebar order. `member_count` counts only the workspaces directly in the group. `is_empty` is `true` only when a group holds nothing, no workspace and no group, so a group with no anchor that still holds groups says `false`. To tell a group with no anchor, read `anchor_workspace_ref`, which is `null` there. `anchor_workspace_id` is never `null`; with no anchor it carries the group's own id as a placeholder.
- `move` reorders a group among the groups beside it, the groups in the same parent (or in the sidebar). It does not move a group into or out of another group. Given a target in a different parent, it fails with an `invalid_params` error, `Target group is not beside this group`, and changes nothing. `--to-index` is an index into the list as `list` returns it. An index past either end, or one that names a group beside it of the other pin state, is brought to the nearest place among its own pin state, and the call succeeds. A move that changes nothing also answers plain success.
- `ungroup`, and `delete` without `--close-workspaces`, dissolve a parent like **Ungroup Workspaces**: its workspaces and child groups move up one group (or into the sidebar) and nothing closes. A pinned group with nothing inside is refused.
- `delete --close-workspaces` on a group that holds groups closes every workspace inside it at every depth, removes the group and every group inside it, and asks nothing. The count in its answer includes every workspace it closed, the anchor of each group too.
- `create --from`, given workspaces that sit inside a group, makes the new group inside that group, as the menu does.
- `remove` given a workspace that is not an anchor moves it out of its group as **Remove from Group** does. Given a group's anchor, it ungroups the whole group.

### Examples

Group two explicitly chosen workspaces under a name:

```bash
cmux workspace-group create --name manaflow --from workspace:1,workspace:2
```

Spin up a new workspace inside an existing group (e.g. wired to a worktree script):

```bash
cmux workspace-group new-workspace workspace_group:1
```

List groups in the focused window:

```bash
cmux workspace-group list
```

Read which group holds which:

```bash
cmux workspace-group list --json
```

Each group in the answer has `"parent_group_id"`: the id of its parent, or `null`.

## On the iPhone

The iPhone lists every group and every workspace but does not show groups inside groups. Two things are refused, and the phone shows the reason:

- **Delete** on a group that holds other groups: *This group holds other groups. Delete it on the Mac.* Nothing closes.
- Dragging the header of a group that sits inside another group: *A group inside another group can only be moved on the Mac.*

Because the phone does not repeat a header, a workspace of a parent that comes after a child group can appear under that child group's rows. No workspace is missing from the phone's list.

## Configuration

Per-group configuration is keyed by the anchor's working directory in `~/.config/cmux/cmux.json` (this surface lands in a follow-up; the file location is reserved). The intent:

```jsonc
{
  "workspaceGroups": {
    // Global default for Cmd-N inside a group, the group header + button, and
    // configured group actions. Per-cwd entries below can override it.
    //   "afterCurrent" (default) - after the active in-group workspace; falls
    //                              back to top when there is no member reference
    //   "top"                    - second slot, right after the anchor
    //   "end"                    - after the trailing member
    "newWorkspacePlacement": "afterCurrent",
    "byCwd": {
      "/Users/you/manaflow/cmux": {
        "color": "#7A4FD8",
        "icon": "ladybug.fill",
        "newWorkspacePlacement": "top",
        "contextMenu": [
          // Entries reference actions defined elsewhere in cmux.json (in the
          // global `actions` block) or built-in actions like "newWorkspace".
          { "action": "newWorktreeAction", "title": "New Worktree" },
          { "action": "newWorkspace" }
        ]
      },
      "~/projects/*": {
        "icon": "leaf.fill",
        "newWorkspacePlacement": "end"
      }
    }
  }
}
```

Matching: keys containing `*` or `?` are globs; otherwise they are path prefixes. Longest match wins.

Resolution order for group new-workspace placement:
1. Explicit `--placement afterCurrent|top|end` on `cmux workspace-group new-workspace`, or `"placement"` in the v2 `workspace.group.new_workspace` params.
2. The per-cwd entry above.
3. Global default via Settings > App > Group New Workspace Placement or `workspaceGroups.newWorkspacePlacement` in `cmux.json` (defaults to `afterCurrent`).

`Cmd-N` inside a group uses the active group workspace as the placement reference. The group header `+` button and CLI path use the anchor as the reference, so `afterCurrent` behaves like `top` there.

## iMessage mode (planned)

When the sidebar is in iMessage mode (latest unread floats to top), the intended behavior for groups is two boolean knobs:

- `sortInsideGroups` (default `true`): workspaces inside each group sort by latest unread; the group's position is unchanged.
- `floatGroups` (default `false`): the whole group reorders by its most-recent unread member.

Neither knob is wired up yet. The current build keeps the sidebar's existing iMessage-mode behavior unchanged regardless of groups. A follow-up will add the `sidebar.imessageMode.*` keys to `cmux.json`, the schema, and the Settings UI; it is documented here so the eventual JSON shape is decided up front.

## Persistence

Groups (name, anchor, pin state, collapse state, color, icon, external identity, anchor provenance, and the group that holds each one) round-trip through `~/Library/Application Support/cmux/session-<bundle-id>.json` alongside workspaces. Membership lives on `Workspace.groupId`, and a group's parent on its `parentGroupId`. Writes are atomic via the existing `SessionPersistenceStore` rename-into-place pattern.

Which group holds which, the order of the rows inside each group, and each group's collapsed, pinned and no-anchor state are the same after cmux quits and reopens. An empty group header stays, pinned or not. A saved file is repaired on restore when a group's parent names no group, or when groups hold each other in a loop: the group with the bad parent is put in the sidebar (for a loop, the first group of it in the saved order), and cmux logs one line for each repair.

## Differences from versions before groups inside groups

Things that behave differently from earlier versions and that you could trip on:

- The **Delete Group** question counts every workspace that closes, the anchor included, so its number is one higher than before for every group, and a pinned group that holds only its anchor now gets a question with a message.
- An empty group header that is not pinned now stays after you quit and reopen cmux. Before, only a pinned one did.
- Clicking the name of a group with no anchor collapses or expands it; before, the click did nothing.
- `create --from`, **New Group from Selection** and `⌘⇧G`, given workspaces that sit inside a group, make the new group inside that group. Before, they made a group in the sidebar.
- **Remove from Group** on a workspace in a child group takes it up one group; before, every group was in the sidebar, so it always left the group for the sidebar.
