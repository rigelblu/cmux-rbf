# Declared agent events

Fork-only (cmux-rbf). This page is for someone writing an agent harness or a hook: how to tell cmux that
a question or an approval is waiting, and when it has been answered, without rebuilding cmux.

A **declared wait** raises the agent's hand on its workspace row (and a notification banner) until it is
answered. Declare one with a hook call; no file, no setting, no flag.

## The four events

| Event | What cmux does |
| --- | --- |
| `QuestionAsked` | Raises the hand and a notification: the agent is waiting for an answer |
| `ApprovalAsked` | Raises the hand and a notification: the agent is waiting for an approval |
| `QuestionAnswered` | Closes the matching `QuestionAsked` wait |
| `ApprovalResolved` | Closes the matching `ApprovalAsked` wait |

"Declared" means these four names, matched ignoring case, spaces and punctuation: `question_answered` and
`Approval.Asked` count. Any other `hook_event_name` keeps the meaning it has today.

## The route

```sh
cmux hooks <agent> notification
```

with a JSON payload on stdin:

| Field | |
| --- | --- |
| `session_id` | The agent's session. Required |
| `hook_event_name` | One of the four names (`event`, `event_name` and `hookEventName` are read too) |
| `request_id` | Your own id for this wait, a string. Required on every declared event: one without it, or with a number, is dropped (Debug builds log it). cmux also reads `tool_use_id` or `tool_call_id` (and the camelCase spellings) as the id, and prefers them over `request_id`, so send only one |
| `message` | Optional. The text the notification shows. Only the top-level `message` is read |

`<agent>` is any built-in agent's slug, `claude` included. Use the slug of the agent whose session
`session_id` names; an unknown slug fails with `Unknown hooks target`.

### Fixed text

With no `message`, cmux attaches its own text, never a word from the agent's last reply:

| Event | Text |
| --- | --- |
| `QuestionAsked` | `Agent is asking a question` (key `feed.notification.question.body`) |
| `ApprovalAsked` | `Approval needed` (key `agent.generic.notification.body.approvalNeeded`) |

### Example: two waits, opened and closed

```sh
h() { "$CMUX_BUNDLED_CLI_PATH" hooks claude notification; }
echo '{"session_id":"s1","hook_event_name":"QuestionAsked","request_id":"q-1","message":"Which branch?"}' | h
echo '{"session_id":"s1","hook_event_name":"ApprovalAsked","request_id":"a-1"}' | h
echo '{"session_id":"s1","hook_event_name":"QuestionAnswered","request_id":"q-1"}' | h
echo '{"session_id":"s1","hook_event_name":"ApprovalResolved","request_id":"a-1"}' | h
echo '{"session_id":"s1","hook_event_name":"SessionEnd"}' | "$CMUX_BUNDLED_CLI_PATH" hooks claude session-end
```

Run it in a cmux terminal pane where no agent is running: a pane with a live Claude session ignores these lines.
Line by line: the question raises the hand, with the banner "Which branch?"; the
approval adds a second wait, with the banner "Approval needed"; answering `q-1` closes only `q-1`, so the
hand stays up; resolving `a-1` closes the last wait and the hand drops; the last line ends session `s1`, so nothing is left
running on the pane. (Don't add `# comments` to these
lines: an interactive zsh doesn't accept them by default.)

An answer whose `request_id` matches no open wait (`q-9`) raises or closes nothing, but it uses that id up
(contract 1). An answer sent from
another pane of the same session closes the wait on the pane that asked.

## Four contracts

1. **A `request_id` never repeats within a session.** An id you have answered stays answered; an ask that
   reuses it raises nothing. That includes an answer for an id with no open wait: it uses the id up, so an ask
   sent later with it raises nothing.
2. **An answer needs a `request_id`.** `QuestionAnswered` or `ApprovalResolved` without one is dropped,
   because with several open waits cmux can't tell which it closes. An ask without a string `request_id` is
   dropped too, because no declared answer could close it. Debug builds log
   `declared answer without request_id dropped` and `declared ask without request_id dropped`.
3. **What closes a wait**, as for every agent: its answer; the user's next prompt; the turn ending (its
   `notification` and `stop` naming the turn its `prompt-submit` started, or naming no turn; one naming a
   turn the session never started is ignored while a wait is open); the session ending or the agent dying;
   a key typed in the pane while it is the only wait; Clear Agent State.
4. **A wait that must outlast its turn is declared after the turn ends.** The turn ending closes every
   open wait, so declare it once the turn's end has been reported.

## Pi forms report themselves

Once cmux's Pi extension from a build with this feature is installed (`cmux hooks pi install`, then
`/reload` in a running pi), nothing else is needed: a pi extension form (`select`, `confirm`, `input`,
`editor` or `custom`) raises the hand while it is open and drops it when it ends.

Which forms count, in plain words:

- A form that opens **during a run**, or **as the run settles**, counts.
- The window stays open until a form that opened inside it ends while pi is idle, or until you type a
  prompt while pi is idle. A form that ends mid-run, and a steer you type while pi works, leave it open.
- One cost of this rule: a form you open yourself after a run that had no form raises the hand until your
  first key in the pane.
- Reopening a form after an accidental Escape raises nothing, because the window closed when the first
  form ended.

The banner uses the form's title; a form with no title (pi gives none to `custom()`) gets
`Agent is asking a question`. Each form's id is `pi-form-<session>-<instance>-<n>`, where `<instance>` is a
fresh UUID each time pi starts the extension: at launch, `/reload`, `/resume`, `/new` and fork. So an id
never repeats. If a form is
still open when the turn ends, cmux asks again after the turn's end with a new id, so the hand returns;
quitting pi with a form open closes it.

Two cases send nothing:

- The extension sends only after a `cmux hooks pi` reply has carried `"cmux_declared_waits": 1`, which
  only a build with this feature prints. A pi still running another build's copy of the extension (the
  file is rewritten at each `hooks pi session-start`, after pi has loaded it) sends nothing until `/reload`.
- A form that opens before pi's first reply from cmux has come back is not sent, and is not asked again.

## Map a notification type

An agent sends cmux a typed notification (Claude's `Notification` hook carries a `notification_type`).
cmux knows what some types mean; for the rest you write one line in your global `~/.config/cmux/cmux.json`,
no rebuild, no restart of cmux or of the agent.

### Find a type cmux doesn't know

The first time ever an agent sends a type no row maps, cmux shows one banner:

- **Title:** `Claude Code · New notification type: worker_permission_prompt`: the agent's name, then the type. If
  macOS cuts the type off a long title, the label becomes `New type:`
- **Subtitle:** the working folder's name, as for every cmux banner
- **Body:** the agent's own message, never words cmux makes up

"Once" means once per agent and type **per cmux app**, remembered across restarts: the dogfood app and each tagged dev
build keep their own record. No hand rises for it. The ping is used up only when its banner can show: one that comes to
the pane you're focused on while cmux is the frontmost app, or to a muted workspace, shows nothing and doesn't count, so
the first one of that type that can show pings. A notification with no type stays silent, and one with a type but no
message of its own gives no banner and doesn't use up the ping either: the first one of that type that has a message
pings. `cmux config doctor` lists the type either way.

`cmux config doctor` lists every such type, newest first, with how many times it came and when it last did, and
prints a row to paste:

```text
Notification types with no row:
  claude  agent_needs_input    2 times, last seen 2026-11-20 14:02
  kimi    plugin_notification  1 time, last seen 2026-11-19 09:15
To map one, add this under agentEvents in ~/.config/cmux/cmux.json:
{ "agent": "claude", "notification": "agent_needs_input", "means": "question" }
```

The list comes from the running app. With no app answering, doctor says so and still checks your rows. It counts one
per notification, and covers the journal cmux still holds (the newest 100,000 events, roughly the last two weeks).

### Write the row

A row is one object in the top-level `agentEvents` list of the **global** file. A repo's own `.cmux/cmux.json` is never
read for rows.

```jsonc
{
  "agentEvents": [
    { "agent": "claude",
      "notification": "worker_permission_prompt",
      "means": "approval" }
  ]
}
```

Save. It applies to the next notification of that type. In a row:

- `agent` is an agent's slug, or `"*"` for every agent
- `notification` is the type exactly as the agent sends it
- `means` is one of four words:

| `means` | The next notification of that type |
| --- | --- |
| `question` | Raises the agent's hand. Banner gated as Claude's question forms are |
| `approval` | Raises the hand, with the approval banner |
| `resolved` | Retires a lone id-less wait that a typed question raised. Gives no banner |
| `ignore` | Gives no banner and no hand, and the type never shows in doctor's list |

**Which row wins:** your row for that exact agent, then your `"*"` row, then the built-in row.

**Deleting a row:** the built-in row comes back. For a type with no built-in row, the type is unmapped again and doctor lists
it. A type that already pinged doesn't ping a second time. A type your row mapped before it ever arrived never pinged, so
its next notification pings once.

**Whole or nothing:** one bad row rejects the whole edit. cmux keeps the last valid rows (or the built-in ones, if it
started with a bad file), shows one `cmux.json Configuration Warning` per bad row at the bottom left of the window and
in the command palette (type `cmux.json`), and `cmux config doctor` prints each one and exits non-zero. A notification row has exactly `agent`, `notification` and `means`: any other
key is a bad row. No two rows share an `agent` and `notification`. A row with a `tool` key in place of `notification` is a
tool row: see "Map a Claude tool" below.

### Which agents a row reaches

`claude`, `antigravity`, `kimi` and `grok`. A row for `pi`, `copilot`, `codebuddy`, `factory` or `hermes-agent` is valid
and does nothing, because their notifications never reach the table. Doctor says so with a line that starts `warning:`
(for example `warning: agentEvents[0] does nothing: pi's notifications never reach it`); it is not an error and doctor still
exits 0. A declared event such as `QuestionAsked` (above) is not a row and needs none.

### Built-in rows

These apply with no file. Copy one into your file to change it; the `idle` row cannot be written in a file.

```jsonc
{ "agent": "*", "notification": "permission_prompt", "means": "approval" }
{ "agent": "*", "notification": "idle_prompt", "means": "idle" }
{ "agent": "*", "notification": "elicitation_dialog", "means": "question" }
{ "agent": "*", "notification": "elicitation_url_dialog", "means": "question" }
{ "agent": "*", "notification": "elicitation_response", "means": "resolved" }
{ "agent": "*", "notification": "elicitation_complete", "means": "resolved" }
```

and these ten types are informational, so they give no banner and no hand:

```jsonc
{ "agent": "*", "notification": "push_notification", "means": "ignore" }
{ "agent": "*", "notification": "auth_success", "means": "ignore" }
{ "agent": "*", "notification": "agent_completed", "means": "ignore" }
{ "agent": "*", "notification": "quota_auto_resume_fired", "means": "ignore" }
{ "agent": "*", "notification": "quota_auto_resume_scheduled", "means": "ignore" }
{ "agent": "*", "notification": "quota_auto_resume_started", "means": "ignore" }
{ "agent": "*", "notification": "quota_auto_resume_stale", "means": "ignore" }
{ "agent": "*", "notification": "quota_auto_resume_disabled", "means": "ignore" }
{ "agent": "*", "notification": "computer_use_enter", "means": "ignore" }
{ "agent": "*", "notification": "computer_use_exit", "means": "ignore" }
```

Every other type pings once: for now `auth_storage_failure`, `plugin_notification`, `agent_needs_input`,
`worker_permission_prompt` and `quota_auto_resume_failed`.

### Three cautions

- A row for `agent_needs_input` may raise the hand on the wrong pane: the type doesn't say which session it names yet.
- A session reached through `cmux ssh` uses the built-in rows only: the table is read from the local app.
- An `ignore` row on `permission_prompt` does not stop Claude's approval hand, which also arrives as a `PermissionRequest`.

## Map a Claude tool

Claude Code's tools that ask you something (`AskUserQuestion`, `ExitPlanMode`) raise your hand while they wait.
When Claude gains a new tool that asks, you give it your hand with one row in the same `agentEvents` list of your global
`~/.config/cmux/cmux.json`. No rebuild, no restart of cmux or of Claude.

### Find the tool's exact name

`tool` is Claude's `tool_name`, matched exactly, case included: `"askuserquestion"` does nothing for `AskUserQuestion`.

- **In the pane:** Claude prints the tool's name above its prompt, as `● <Name>(…)`
- **In the release notes:** Claude Code's release notes name each new tool

### Write the row

```jsonc
{
  "agentEvents": [
    { "agent": "claude", "tool": "NewAskingTool", "means": "question" }
  ]
}
```

`NewAskingTool` stands for the new tool's exact name; there is none yet.

Save. It applies to the tool's next call. In a tool row:

- `agent` is `"claude"` or `"*"`. A row for any other agent is valid and does nothing: only Claude's tool hooks read tool
  rows. Doctor says so with a `warning:` line and still exits 0
- `tool` is the tool's exact name
- `means` is one of two words:

| `means` | When the tool starts |
| --- | --- |
| `question` | Raises the hand and the `Needs input` status, and shows one banner |
| `plan-review` | The same, for a tool that waits for you to review a plan |

`ignore`, `approval`, `resolved` and `idle` are bad on a tool row. A row has `notification` or `tool`, never both.

**What you see.** The hand rises on the workspace row and one banner comes, in every permission mode:
`Claude Code · Needs your answer`, subtitle the working folder, body `Waiting for input`. cmux doesn't know a new tool's
input, so the banner carries no question text.

**Where you answer.** In Claude's own prompt in the terminal. A row tool gets **no Feed card**, and you can't answer it from
the Feed or your phone: cmux tells Claude at once that it has no decision, so Claude shows its own prompt and nothing holds
it. `AskUserQuestion` and `ExitPlanMode` keep their Feed cards.

**Where the hand drops.** At your first key in the pane while it is the only wait, or when the tool ends. A call you decline,
interrupt or that fails sends no end signal, so its hand drops at your next key or when the turn ends. With two calls open at
once, your first key drops neither, and each drops when its own call ends. Claude's own "needs your permission" notification
a few seconds later brings no second banner while the wait is open, and brings no hand back after you answered it quickly
(less than 10 s after the call started); a later one with no wait behind it raises the approval hand as before.

**Which row wins:** your row for `claude`, then your `"*"` row, then the built-in row. **Whole or nothing:** one bad row
rejects the whole edit, as for notification rows. cmux keeps the last valid rows for the hand, but a row tool's permission
shows today's approval card until the file is fixed. Doctor and the palette name the row and the fix.

### Built-in tool rows

These apply with no file and give today's behaviour exactly. Copy one into your file to change its word.

```jsonc
{ "agent": "claude", "tool": "AskUserQuestion", "means": "question" }
{ "agent": "claude", "tool": "ExitPlanMode", "means": "plan-review" }
```

A row of yours that says the same word as the built-in row changes nothing. A row that changes it (`AskUserQuestion` to
`plan-review`) makes the tool a row tool: no question text and no Feed card.

### Cautions

- **Update the app before you add a tool row.** An older app rejects the whole edit, because `tool` is an unknown key there,
  and keeps its last valid rows
- **Tool rows are local only.** A session reached through `cmux ssh` keeps the built-in rows
- **A stand-in row is a test, not a use.** A row for a tool that never asks (`Write`, `Bash`) raises the hand on every call of
  it, and moves every call's hooks into the queue's lifecycle class, where they compete with prompts and notifications for its
  eight slots. Delete a stand-in after you try it
- **A payload over 64 KB** loses its call id, so its hand drops at your key or the turn's end, not when the tool ends
