extension CMUXCLI {
    static let piExtensionSourcePart2 = #"""
async function sendHook(
  dispatcher: PiCmuxCommandDispatcher,
  subcommand: string,
  context: PiExtensionContextSnapshot,
  extra: HookExtra = {},
): Promise<boolean> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  const sessionId = context.sessionId;
  if (!sessionId) return true;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return !firstString(process.env.CMUX_PANEL_ID);

  const cwd = context.cwd;
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const result = await dispatcher.run(
    ["hooks", "pi", subcommand, ...target],
    cwd,
    JSON.stringify(payload),
    context,
  );
  if (result.ok) {
    rememberSurfaceTarget(dispatcher, sessionId, result);
    // (#cm-124.2) The latch turns on at the first parsed ok reply that carries the key and never turns off:
    // a non-ok or unparsable reply is ignored, and one pi process can't switch to another CLI.
    if (parseJSONOutput(result)?.cmux_declared_waits === 1) declaredWaitsSupportedBy.add(dispatcher);
  }
  return result.ok;
}

// (#cm-124.2) Dispatchers whose cmux CLI has answered with `"cmux_declared_waits": 1`. One dispatcher per
// default-export call, so a reloaded extension latches again from its own first reply.
const declaredWaitsSupportedBy = new WeakSet<PiCmuxCommandDispatcher>();

const resolvedSurfaceTargets = new WeakMap<PiCmuxCommandDispatcher, Map<string, string[]>>();

function surfaceTargetsFor(dispatcher: PiCmuxCommandDispatcher): Map<string, string[]> {
  let targets = resolvedSurfaceTargets.get(dispatcher);
  if (!targets) {
    targets = new Map();
    resolvedSurfaceTargets.set(dispatcher, targets);
  }
  return targets;
}

function surfaceTargetArgs(dispatcher: PiCmuxCommandDispatcher, sessionId: string): string[] | null {
  const resolved = surfaceTargetsFor(dispatcher).get(sessionId);
  if (resolved) return [...resolved];
  const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
  if (!surfaceId) return null;
  const args: string[] = [];
  const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
  if (workspaceId) args.push("--workspace", workspaceId);
  args.push("--surface", surfaceId);
  return args;
}

function rememberSurfaceTarget(
  dispatcher: PiCmuxCommandDispatcher,
  sessionId: string,
  result: CommandResult,
): void {
  const payload = parseJSONOutput(result);
  const workspaceId = firstString(payload?.workspace_id);
  const surfaceId = firstString(payload?.surface_id);
  if (!workspaceId || !surfaceId) return;
  surfaceTargetsFor(dispatcher).set(
    sessionId,
    ["--workspace", workspaceId, "--surface", surfaceId],
  );
}

function releaseSessionRuntime(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  sessionId: string,
): void {
  dispatcher.releaseSession(sessionId);
  sessionStates.delete(sessionId);
  surfaceTargetsFor(dispatcher).delete(sessionId);
}

function parseJSONOutput(result: CommandResult): Record<string, unknown> | null {
  if (!result.ok) return null;
  try {
    const parsed = JSON.parse(result.stdout);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch (_) {
    return null;
  }
}

async function clearResumeBinding(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return;
  const cwd = context.cwd;
  await dispatcher.run([
    "--json",
    "surface",
    "resume",
    "clear",
    ...target,
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
  ], cwd, undefined, context);
}

type PiFeedEventName =
  | "PreToolUse"
  | "PostToolUse"
  | "PreCompact"
  | "PostCompact"
  | "SubagentStart"
  | "SubagentStop";

const subagentToolNames = new Set([
  "subagent",
  "team_spawn",
  "superpowers_dispatch",
  "Task",
]);

function isSubagentTool(event: unknown): boolean {
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  return toolName !== null && (subagentToolNames.has(toolName) || /subagent/i.test(toolName));
}

function isTerminalFeedEvent(eventName: PiFeedEventName): boolean {
  return eventName === "PostToolUse" || eventName === "SubagentStop";
}

function prepareFeedDispatch(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  eventName: PiFeedEventName,
  context: PiExtensionContextSnapshot,
  event: unknown,
): (() => void) | undefined {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return undefined;
  const sessionId = context.sessionId;
  if (!sessionId) return undefined;
  if (!dispatcher.canDispatch(sessionId)) return undefined;
  const state = stateFor(sessionStates, sessionId);
  if (state.stopped) return undefined;
  const cwd = context.cwd;
  const toolCallId = firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"]));
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  const turnId = currentTurnId(sessionStates, sessionId, event);
  const toolInput = objectValue(event, ["args", "input"]);
  const terminal = isTerminalFeedEvent(eventName);
  const toolResult = terminal
    ? objectValue(event, ["result", "details", "content"])
    : undefined;
  const isError = terminal ? objectValue(event, ["isError", "is_error"]) : undefined;
  return () => {
    const target = surfaceTargetArgs(dispatcher, sessionId);
    if (!target) return;

    // Pi invokes tool lifecycle handlers on its UI event loop. Keep those
    // callbacks lightweight by traversing and bounding tool payloads only in
    // the already-detached lifecycle task.
    const projectionState: PiFeedProjectionState = { remainingNodes: 48, seen: new WeakSet() };
    const payload: HookExtra = {
      session_id: utf8Prefix(sessionId, 256),
      cwd: utf8Prefix(cwd, 2048),
      hook_event_name: eventName,
      event: eventName,
      turn_id: utf8Prefix(turnId, 256),
    };
    const boundedToolCallId = utf8Prefix(toolCallId, 256);
    if (boundedToolCallId !== undefined) payload.tool_call_id = boundedToolCallId;
    const boundedToolName = utf8Prefix(toolName, 256);
    if (boundedToolName !== undefined) payload.tool_name = boundedToolName;
    if (toolInput !== undefined) payload.tool_input = projectPiFeedValue(toolInput, projectionState);
    if (toolResult !== undefined) {
      payload.tool_result = projectPiFeedValue(toolResult, projectionState, 0, false);
    }
    if (isError !== undefined) payload.is_error = projectPiFeedValue(isError, projectionState);
    dispatcher.enqueueFeed(`${sessionId}:${toolCallId || toolName || "unknown"}`, {
      args: ["hooks", "feed", "--source", "pi", "--event", eventName, ...target],
      cwd,
      payload,
      context,
      terminal,
      onFailure: () => { state.feedDeliveryFailed = true; },
    });
  };
}

async function warnFeedDeliveryDropped(
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  await warn(context, "cmux feed delivery dropped", {
    session_id: sessionId,
    hook_name: "feed",
    reason: "dispatch-dropped",
  });
}

async function publishPendingCompletion(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  context: PiExtensionContextSnapshot,
  sessionId: string,
  completion: PendingCompletion,
): Promise<void> {
  await dispatcher.finishFeedForSession(sessionId);
  const state = stateFor(sessionStates, sessionId);
  const feedDelivered = !state.feedDeliveryFailed;
  state.feedDeliveryFailed = false;
  if (!feedDelivered) await warnFeedDeliveryDropped(context, sessionId);
  const stopPayload: HookExtra = {
    last_assistant_message: completion.lastAssistantMessage,
    turn_id: completion.turnId,
  };
  if (completion.suppressNotification) {
    // Stop normally creates cmux's native fallback notification when no explicit
    // notification was routed. Mark intentional interruption as already handled.
    stopPayload.cmux_notification_routed = true;
  } else if (feedDelivered) {
    const notificationRouted = await sendHook(dispatcher, "notification", context, {
      message: completion.lastAssistantMessage || "Task completed",
      turn_id: completion.turnId,
      notification: { type: completion.notificationType },
    });
    if (notificationRouted) stopPayload.cmux_notification_routed = true;
  }
  await sendHook(dispatcher, "stop", context, stopPayload);
}

// A stalled lifecycle hook may run for its full configured timeout while Pi
// keeps emitting tool events. Bound the pending tasks a session can stack
// behind it so bursts cannot pin unbounded event payloads: droppable Feed
// preparation is shed first and surfaces as a dropped delivery at completion.
const maximumPiLifecycleBacklogTasks = 32;

interface PiLifecycleQueue {
  enqueue(
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): Promise<void>;
  tryEnqueue(
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): boolean;
}

function createPiLifecycleQueue(): PiLifecycleQueue {
  const tails = new Map<string, Promise<void>>();
  const pendingCounts = new Map<string, number>();
  const enqueue = (
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): Promise<void> => {
    pendingCounts.set(sessionId, (pendingCounts.get(sessionId) || 0) + 1);
    const previous = tails.get(sessionId) || Promise.resolve();
    let tracked: Promise<void>;
    tracked = previous
      .then(operation)
      .then(() => undefined)
      .catch((error) => {
        const errorMessage = error instanceof Error ? error.message : undefined;
        return warn(context, "cmux lifecycle task failed", {
          hook_name: "lifecycle-task",
          reason: "extension-error",
          error_available: error !== undefined,
          error_message: utf8Prefix(errorMessage, 512),
        });
      })
      .finally(() => {
        const remaining = (pendingCounts.get(sessionId) || 1) - 1;
        if (remaining > 0) pendingCounts.set(sessionId, remaining);
        else pendingCounts.delete(sessionId);
        if (tails.get(sessionId) === tracked) tails.delete(sessionId);
      });
    tails.set(sessionId, tracked);
    return tracked;
  };
  return {
    enqueue,
    tryEnqueue(sessionId, context, operation) {
      if ((pendingCounts.get(sessionId) || 0) >= maximumPiLifecycleBacklogTasks) return false;
      void enqueue(sessionId, context, operation);
      return true;
    },
  };
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  const dispatcher = new PiCmuxCommandDispatcher();
  const sessionStates = new Map<string, SessionState>();
  const lifecycleTasks = createPiLifecycleQueue();
  // (#cm-124.2) A full UUID minted in each call of this default export. A module-level id would repeat across
  // /resume, /new and fork, which build a new factory call but keep pi's module cache.
  const extensionInstanceId = randomUUID();

  const enqueueLifecycleTask = (
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ): Promise<void> => lifecycleTasks.enqueue(sessionId, context, operation);

  // (#cm-124.2) Declared form waits. Both sends go through the lifecycle queue, never `tryEnqueue`.
  const sendFormAsk = async (
    context: PiExtensionContextSnapshot,
    span: FormSpan,
  ): Promise<void> => {
    await sendHook(dispatcher, "notification", context, {
      hook_event_name: "QuestionAsked",
      event: "QuestionAsked",
      request_id: span.requestId,
      ...(span.title ? { message: span.title } : {}),
    });
  };

  const sendFormAnswer = async (
    context: PiExtensionContextSnapshot,
    requestId: string,
  ): Promise<void> => {
    await sendHook(dispatcher, "notification", context, {
      hook_event_name: "QuestionAnswered",
      event: "QuestionAnswered",
      request_id: requestId,
    });
  };

  const mintFormRequestId = (state: SessionState, sessionId: string): string => {
    state.nextFormIndex += 1;
    return `pi-form-${sessionId}-${extensionInstanceId}-${state.nextFormIndex}`;
  };

  pi.on("session_start", (_event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (sessionId) {
      const state = stateFor(sessionStates, sessionId);
      state.pendingCompletion = undefined;
      state.feedDeliveryFailed = false;
      state.stopped = false;
      state.formWindowOpen = false; // (#cm-124.2)
      state.activeFormSpan = undefined; // (#cm-124.2)
    }
    if (!sessionId) return;
    enqueueLifecycleTask(sessionId, context, async () => {
      await sendHook(dispatcher, "session-start", context);
    });
  });

  pi.on("before_agent_start", (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const turnId = beginTurn(sessionStates, sessionId, event);
    stateFor(sessionStates, sessionId).formWindowOpen = true; // (#cm-124.2) the window opens with the run
    enqueueLifecycleTask(sessionId, context, () => (
      sendHook(dispatcher, "prompt-submit", context, { prompt: event.prompt, turn_id: turnId })
    ));
  });

  // (#cm-124.2) A prompt he types while pi is idle closes the window; a steer while pi works leaves it open.
  pi.on("input", (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    if (!sessionId) return;
    if (event.streamingBehavior === undefined && ctx.isIdle()) {
      stateFor(sessionStates, sessionId).formWindowOpen = false;
    }
  });

  // (#cm-124.2) Pi doesn't await ui_prompt_* handlers, so these only record state and enqueue.
  pi.on("ui_prompt_start", (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    if (!state.formWindowOpen || state.activeFormSpan) return;
    const title = firstString(event.title);
    const span: FormSpan = { requestId: "", asked: false, ...(title ? { title } : {}) };
    state.activeFormSpan = span;
    if (!declaredWaitsSupportedBy.has(dispatcher)) return;
    span.requestId = mintFormRequestId(state, sessionId);
    span.asked = true;
    enqueueLifecycleTask(sessionId, context, () => sendFormAsk(context, span));
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    const span = state.activeFormSpan;
    if (!span) return;
    state.activeFormSpan = undefined;
    // The id is read when the task runs: a re-ask queued before this end may have replaced it.
    if (span.asked) enqueueLifecycleTask(sessionId, context, () => sendFormAnswer(context, span.requestId));
    // A counted form that ends while pi is idle closes the window.
    if (ctx.isIdle()) state.formWindowOpen = false;
  });

  const enqueueFeed = (
    eventName: PiFeedEventName,
    event: unknown,
    ctx: ExtensionContext,
  ): void => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const dispatch = prepareFeedDispatch(dispatcher, sessionStates, eventName, context, event);
    if (!dispatch) return;
    if (!lifecycleTasks.tryEnqueue(sessionId, context, dispatch)) {
      // A shed completion must fail visibly instead of reporting delivery.
      if (isTerminalFeedEvent(eventName)) stateFor(sessionStates, sessionId).feedDeliveryFailed = true;
    }
  };

  pi.on("tool_execution_start", (event, ctx) => {
    enqueueFeed(isSubagentTool(event) ? "SubagentStart" : "PreToolUse", event, ctx);
  });

  pi.on("tool_execution_end", (event, ctx) => {
    enqueueFeed(isSubagentTool(event) ? "SubagentStop" : "PostToolUse", event, ctx);
  });

  pi.on("session_before_compact", (event, ctx) => {
    enqueueFeed("PreCompact", event, ctx);
  });

  pi.on("session_compact", (event, ctx) => {
    enqueueFeed("PostCompact", event, ctx);
  });

  pi.on("agent_end", (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    const assistantCompletion = assistantCompletionFrom(event);
    // Preserve the latest low-level result until Pi confirms no automatic work remains.
    state.pendingCompletion = {
      lastAssistantMessage: assistantCompletion.lastAssistantMessage || state.pendingCompletion?.lastAssistantMessage,
      notificationType: firstString(objectValue(event, ["stopReason", "reason", "terminationReason"])) || "completed",
      turnId: currentTurnId(sessionStates, sessionId, event),
      suppressNotification: assistantCompletion.suppressNotification,
    };
    // Older Pi versions do not emit agent_settled, so retain their established completion behavior.
    // (#cm-124.2) No form re-ask on this path, and no pi that reaches it has forms: ui_prompt_* came after
    // agent_settled (pi CHANGELOG.md:875 vs :1600).
    if (!supportsAgentSettled()) {
      const completion = settleTurn(sessionStates, sessionId);
      if (completion) {
        enqueueLifecycleTask(sessionId, context, () => (
          publishPendingCompletion(dispatcher, sessionStates, context, sessionId, completion)
        ));
      }
    }
  });

  pi.on("agent_settled", (_event, ctx) => {
    const context = snapshotContext(ctx);
    const isIdle = ctx.isIdle();
    const sessionId = context.sessionId;
    if (!sessionId || !isIdle) return;
    // Consume pending completion before subprocess calls so duplicate settlement cannot notify twice.
    const completion = settleTurn(sessionStates, sessionId);
    if (completion) {
      // (#cm-124.2) Snapshot the form whose ask is already queued: the turn's end below closes its wait, so it
      // gets a fresh ask after the stop. A form that opens after this handler is not re-asked.
      const state = stateFor(sessionStates, sessionId);
      const snapshottedSpan = state.activeFormSpan?.asked ? state.activeFormSpan : undefined;
      enqueueLifecycleTask(sessionId, context, async () => {
        await publishPendingCompletion(dispatcher, sessionStates, context, sessionId, completion);
        if (!snapshottedSpan || state.activeFormSpan !== snapshottedSpan) return;
        snapshottedSpan.requestId = mintFormRequestId(state, sessionId);
        await sendFormAsk(context, snapshottedSpan);
      });
    }
  });

  pi.on("session_shutdown", async (event, ctx) => {
    const context = snapshotContext(ctx);
    const sessionId = context.sessionId;
    if (!sessionId) return;
    const state = stateFor(sessionStates, sessionId);
    // (#cm-124.2) A form still open at shutdown gets its one QuestionAnswered, with the span's current id.
    const openSpan = state.activeFormSpan;
    state.activeFormSpan = undefined;
    state.formWindowOpen = false;
    let stopPayload: HookExtra | undefined;
    if (!state.stopped) {
      const turnId = finishTurn(sessionStates, sessionId, event);
      stopPayload = {
        turn_id: turnId,
        terminationReason: firstString(objectValue(event, ["reason"])) || "session_shutdown",
      };
    }
    await enqueueLifecycleTask(sessionId, context, async () => {
      if (openSpan?.asked) await sendFormAnswer(context, openSpan.requestId); // (#cm-124.2)
      await dispatcher.finishFeedForSession(sessionId);
      const feedDelivered = !state.feedDeliveryFailed;
      state.feedDeliveryFailed = false;
      if (!feedDelivered) await warnFeedDeliveryDropped(context, sessionId);
      if (stopPayload) await sendHook(dispatcher, "stop", context, stopPayload);
      try {
        await clearResumeBinding(dispatcher, context, sessionId);
      } finally {
        releaseSessionRuntime(dispatcher, sessionStates, sessionId);
      }
    });
  });
}
"""#
}
