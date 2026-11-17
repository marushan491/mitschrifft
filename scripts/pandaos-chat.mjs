import { realpath } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function catalog(snapshot) {
  return snapshot.entries.filter(entry => entry.enabled && entry.status === "ready").flatMap(entry =>
    (entry.models ?? []).filter(model => model.isSelectable !== false).map(model => ({
      id: model.id, title: model.label ?? model.id, account: entry.provider,
      provider: "pandaos", accountTitle: entry.label ?? entry.provider,
      efforts: (model.thinkingOptions ?? []).map(option => option.id)
    })));
}

export async function chat(client, input) {
  const snapshot = await client.getProvidersSnapshot();
  const provider = snapshot.entries.find(entry => entry.provider === input.account && entry.enabled && entry.status === "ready");
  if (!provider) throw new Error("PandaOS-Provider ist nicht verfügbar. Bitte ein anderes Konto wählen.");
  const model = (provider.models ?? []).find(model => model.id === input.model && model.isSelectable !== false);
  if (!model)
    throw new Error("Das gewählte Modell ist bei diesem PandaOS-Konto nicht verfügbar.");
  const effort = model.thinkingOptions?.some(option => option.id === input.effort) ? input.effort : model.defaultThinkingOptionId;
  const existing = await client.fetchAgent(input.conversationID);
  const labels = {"mitschrift.chat": input.conversationID, "mitschrift.choice": input.selectionID};
  let agent;
  if (existing) {
    agent = existing.agent;
    if (agent.labels?.["mitschrift.chat"] !== input.conversationID || agent.archivedAt)
      throw new Error("Diese PandaOS-Session gehört nicht zum aktuellen Mitschrift-Chat.");
    if (agent.labels?.["mitschrift.choice"] !== input.selectionID) {
      if (agent.status === "running") throw new Error("PandaOS arbeitet noch. Vor dem Providerwechsel dort warten oder abbrechen.");
      await client.setAgentProvider(agent.id, input.account, input.model);
      await client.setAgentThinkingOption(agent.id, effort ?? null);
      await client.updateAgent(agent.id, {labels});
    }
    if (agent.labels?.["mitschrift.request"] !== input.requestID) {
      await client.sendMessage(agent.id, input.prompt, {messageId: input.requestID, images: input.images, activeTurnBehavior: "steer"});
      await client.updateAgent(agent.id, {labels: {"mitschrift.request": input.requestID}});
    }
  } else {
    const workspaces = await client.fetchWorkspaces({filter: {query: input.workspace}, page: {limit: 200}});
    const workspace = workspaces.entries.find(entry => entry.id === input.workspace);
    if (!workspace) throw new Error("Der konfigurierte Mitschrift-Arbeitsbereich fehlt in PandaOS.");
    agent = await client.createAgent({agentId: input.conversationID, workspaceId: workspace.id, cwd: workspace.workspaceDirectory,
      provider: input.account, model: input.model, thinkingOptionId: effort,
      modeId: provider.defaultModeId ?? undefined, title: "Mitschrift Chat", labels: {...labels, "mitschrift.request": input.requestID},
      clientMessageId: input.requestID, idempotencyKey: input.requestID,
      initialPrompt: input.prompt, images: input.images});
  }
  const state = await client.waitForFinish(agent.id, 180000);
  const final = state.final ?? agent;
  const pending = state.status !== "idle" || !state.lastMessage?.trim();
  const answer = pending ? (state.status === "permission" ? "PandaOS wartet auf deine Freigabe. Über „In PandaOS öffnen“ fortsetzen." :
    final.routingNotice?.reason ?? state.error ?? "PandaOS arbeitet noch. Über „In PandaOS öffnen“ fortsetzen; die Anfrage bleibt dort erhalten.") : state.lastMessage.trim();
  return {answer, pending, sessionID: agent.id, model: final.model ?? input.model,
    account: "PandaOS / " + final.provider, effort: final.effectiveThinkingOptionId ?? final.thinkingOptionId ?? effort ?? "Standard"};
}

async function main() {
  let raw = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) {
    raw += chunk;
    if (Buffer.byteLength(raw) > 16000000) throw new Error("PandaOS-Anfrage zu groß.");
  }
  const input = JSON.parse(raw);
  if (!["catalog", "chat"].includes(input.mode)) throw new Error("PandaOS-Modus unlesbar.");
  const cli = await realpath(process.env.MITSCHRIFT_PANDAOS_CLI ?? input.cli);
  const directory = path.resolve(path.dirname(cli), "../dist/utils");
  const {connectToDaemon} = await import(pathToFileURL(path.join(directory, "client.js")));
  const {selectDaemonTarget} = await import(pathToFileURL(path.join(directory, "daemon-target.js")));
  const client = await connectToDaemon({target: selectDaemonTarget({})});
  try {
    const result = input.mode === "catalog" ? catalog(await client.getProvidersSnapshot()) : await chat(client, input);
    process.stdout.write(JSON.stringify(result));
  } finally { await client.close(); }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main().catch(error => {
    const message = String(error.message ?? error);
    process.stderr.write(message.includes("agent_request_outcome_unknown") || message.includes("agent_request_key_conflict") ?
      "Anfragestatus unklar. Bitte in PandaOS nachsehen; nicht automatisch erneut ausführen." : message);
    process.exitCode = 1;
  });
}
