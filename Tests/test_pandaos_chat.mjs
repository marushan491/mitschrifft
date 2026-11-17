import test from "node:test";
import assert from "node:assert/strict";
import {catalog, chat} from "../scripts/pandaos-chat.mjs";

const entries = ["codex-business", "codex-plus", "claude-team"].map(provider => ({
  provider, enabled: true, status: "ready", label: provider, defaultModeId: "auto",
  models: [{id: "same-model", label: "Model", thinkingOptions: [{id: "high"}]}, {id: "hidden", isSelectable: false}]
}));
const input = {conversationID: "test-chat", requestID: "test-message", selectionID: "choice-1",
  workspace: "test-workspace", account: "codex-plus", model: "same-model", effort: "high",
  prompt: "Synthetische Frage mit bisherigem Kontext", images: []};
function fixture(agent = null, state = {}) {
  const calls = [];
  const client = {
    getProvidersSnapshot: async () => ({entries}),
    fetchAgent: async () => agent ? {agent} : null,
    fetchWorkspaces: async () => ({entries: [{id: input.workspace, workspaceDirectory: "/synthetic"}]}),
    createAgent: async config => {calls.push(["create", config]); agent = {id: config.agentId, labels: config.labels, status: "idle"}; return agent;},
    setAgentProvider: async (...args) => calls.push(["provider", ...args]),
    setAgentThinkingOption: async (...args) => calls.push(["thinking", ...args]),
    updateAgent: async (...args) => {calls.push(["update", ...args]); agent.labels = {...agent.labels, ...args[1].labels};},
    sendMessage: async (...args) => calls.push(["send", ...args]),
    waitForFinish: async () => ({status: "idle", lastMessage: "Dienstag", final: {provider: "codex-plus", model: "same-model"}, ...state})
  };
  return {client, calls};
}
test("catalog retains separate accounts with the same model and excludes unavailable entries", () => {
  const models = catalog({entries: [...entries, {enabled: false, models: [{id: "other"}]}]});
  assert.deepEqual(models.map(model => model.account), entries.map(entry => entry.provider));
});
test("new chat uses the configured PandaOS profile and stable IDs", async () => {
  const {client, calls} = fixture();
  const reply = await chat(client, input);
  assert.equal(calls[0][1].provider, "codex-plus");
  assert.equal(calls[0][1].clientMessageId, input.requestID);
  assert.equal(calls[0][1].initialPrompt, input.prompt);
  assert.equal(reply.sessionID, input.conversationID);
  assert.equal(reply.pending, false);
});
test("provider change keeps the session and context", async () => {
  const agent = {id: input.conversationID, status: "idle", labels: {"mitschrift.chat": input.conversationID, "mitschrift.choice": "old"}};
  const {client, calls} = fixture(agent);
  await chat(client, input);
  assert.deepEqual(calls[0], ["provider", input.conversationID, "codex-plus", "same-model"]);
  assert.equal(calls.find(call => call[0] === "send")[2], input.prompt);
  assert.equal(calls.find(call => call[0] === "send")[3].messageId, input.requestID);
  assert.equal(calls.some(call => call[0] === "create"), false);
});
test("daemon quota rotation is retained until the user changes their selection", async () => {
  const agent = {id: input.conversationID, status: "idle", provider: "codex-business",
    labels: {"mitschrift.chat": input.conversationID, "mitschrift.choice": input.selectionID}};
  const {client, calls} = fixture(agent, {final: {provider: "claude-team", model: "fallback"}});
  const result = await chat(client, input);
  assert.equal(calls.some(call => call[0] === "provider"), false);
  assert.equal(result.account, "PandaOS / claude-team");
});
test("exhausted quota and permission states expose the existing session", async () => {
  for (const state of [{status: "timeout", lastMessage: null, final: {provider: "codex-plus", routingNotice: {reason: "Limit erreicht"}}},
                       {status: "permission", lastMessage: null}]) {
    const {client} = fixture(null, state);
    const result = await chat(client, input);
    assert.equal(result.pending, true);
    assert.equal(result.sessionID, input.conversationID);
    assert.ok(result.answer.includes(state.status === "permission" ? "Freigabe" : "Limit"));
  }
});
test("an unrelated session is never used", async () => {
  const {client, calls} = fixture({id: input.conversationID, labels: {}});
  await assert.rejects(chat(client, input), /gehört nicht/);
  assert.equal(calls.length, 0);
});

test("retry of the first pending request waits without sending or executing again", async () => {
  const {client, calls} = fixture(null, {status: "timeout", lastMessage: null});
  await chat(client, input);
  await chat(client, {...input, prompt: "Späteres Transkript, dieselbe offene Frage"});
  assert.equal(calls.filter(call => call[0] === "create").length, 1);
  assert.equal(calls.filter(call => call[0] === "send").length, 0);
});
test("retry of a following pending request only waits", async () => {
  const agent = {id: input.conversationID, status: "idle", labels: {"mitschrift.chat": input.conversationID, "mitschrift.choice": input.selectionID}};
  const {client, calls} = fixture(agent, {status: "timeout", lastMessage: null});
  await chat(client, input);
  await chat(client, {...input, prompt: "Ein neuer Zeitstempel"});
  assert.equal(calls.filter(call => call[0] === "send").length, 1);
});
test("providers without thinking options receive no unsupported effort", async () => {
  const {client, calls} = fixture();
  client.getProvidersSnapshot = async () => ({entries: [{...entries[1], models: [{id: "same-model"}]}]});
  await chat(client, input);
  assert.equal(calls[0][1].thinkingOptionId, undefined);
});
