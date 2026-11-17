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
