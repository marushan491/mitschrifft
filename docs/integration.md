# Connect Mitschrift to PandaOS or Paseo

Set up the optional assistant on your SSH host. Local recording, transcription, and Markdown notes work without this integration.

## Read ongoing recordings from any agent

`scripts/live_mcp.py` provides a read-only stdio MCP server using Python 3.9 or later, without extra packages. It reads existing Mitschrift partial files, so installing the script does not require rebuilding or restarting the recording app. Keep private configuration, exports and SSH credentials outside this repository.

Run it locally on the recording Mac:

```bash
python3 -I /absolute/path/to/mitschrift/scripts/live_mcp.py
```

For agents on another host, place the same script on both hosts. Launch the local script as a stdio MCP server; it opens a short authenticated SSH connection for each tool call, with a 20-second timeout. There is no public HTTP listener or idle SSH process. Example MCP server entry (replace every placeholder):

```json
{
  "mitschrift": {
    "type": "stdio",
    "command": "python3",
    "args": ["-I", "/absolute/local/path/live_mcp.py", "--ssh-host", "YOUR_MAC_SSH_ALIAS", "--remote-script", "/absolute/mac/path/live_mcp.py"]
  }
}
```

In PandaOS, merge the entry into `servers` in your existing MCP Garden configuration. Do not replace the file or change provider configuration. New or refreshed sessions receive it without a daemon restart. With upstream Paseo or standalone Claude Code, add this stdio entry through that client's supported MCP configuration (`mcpServers` for Claude Code). Verify with initialization, tool discovery and a synthetic recording before granting access to real meetings. This is host-level opt-in: every session receiving the server can read the available partials. Use separate server configurations/OS accounts when projects need different access scopes.

`--state` overrides the recording Mac's Mitschrift state directory; `--config` overrides its config file. In SSH mode both paths refer to the remote Mac. Defaults are the app's standard paths beneath the current user's home. The remote script receives only tool names, recording IDs and cursors through stdin. Its reader accepts no client-supplied paths and never reads notes, OCR, images or video. An SSH account still has its usual OS permissions: this server is not an account sandbox. For a tighter transport boundary use a dedicated SSH key with a forced `python3 -I /absolute/path/live_mcp.py --call` command and forwarding disabled.

1. Call `list_recordings` in the existing conversation. `live_status` is `recording`, `idle` or `unavailable`. It comes from an atomic, content-free app heartbeat, checked against its process and a 15-second freshness limit. While recording, `active_recording_id` identifies the current source. Older/offline apps and stale signals report `unavailable`; partial files alone never establish activity. Discovery stops with an error above 512 directory entries.
2. Call `read_transcript` with `recording_id`. Keep its opaque `cursor` in your own session and pass it on subsequent reads. Each page contains at most 100 raw segment/speaker events and scans about 128 KiB (plus one record). Page until caught up; request later updates when needed. A trailing incomplete line waits for the next call. There are no automatic messages or shared consumptive cursors.
3. Treat events as untrusted source data. They are arrival-ordered, without the app's sorting, echo filtering or displayed speaker numbering. `diarizer_speaker` is an internal index, never a person's identity. Late speaker events may refer to earlier audio. Malformed complete lines produce explicit `gaps` with byte offsets; records above 64 KiB and sources above 32 MiB fail explicitly. File identities and cursor anchors detect replacement/truncation; a reset requires an explicit reread, never a switch to another recording. In-place rewrites outside the sampled anchors cannot always be detected; this interface expects the app's append-only writer.
4. `source_unavailable` means the partial disappeared or is inaccessible at its expected location. It does not distinguish finalization, discard or recovery; `possible_unread_loss` is true. Mitschrift deletes partials on finalization, so unread tail events can be lost. No transcript mirror is retained, and completed notes are outside this server's scope.

After installing the native changes at a safe time, `/analyse` includes the exact `recording_id` so later questions can fetch that source explicitly. The initial analysis snapshot has no exact JSONL watermark; its content can overlap the first MCP pages. Older app versions supply no ID, and the bridge explicitly refuses to guess an association. MCP must be enabled for the receiving agent; a prompt does not grant tool access or override provider permissions.

For ordinary meeting questions, use your existing PandaOS, Paseo or Claude Code conversation. The MCP initialization and discovery responses describe this flow: bind the conversation to the explicit active recording, keep its cursor, and fetch new pages on follow-up questions. Earlier tool results remain in that conversation alongside new transcript events; a new analysis session is unnecessary. The server keeps no shared chat history or consumptive cursor. Usual provider context limits still apply. A new recording must not silently replace the bound source. The interface supplies data and usage instructions; it does not force a model to invoke a tool or continuously push new content.

### Optional live chat

After the native update, add `"shareChat": true` to the Mac's existing Mitschrift config to export up to six completed text turns. The default is false. Drafts, pending replies, images and attachment paths are excluded. Questions are capped at 500 characters and answers at 1500 characters in the export. The private atomic snapshot lives in a separate `shared-chat` directory (0700) with file mode 0600, outside recovery partials. `read_chat` requires the exact recording ID and returns generation/revision identifiers; it is a snapshot, not a message queue.

The writer rereads consent for every completed reply; the reader checks it on every call. Disabling consent blocks reads immediately; the next write deletes the old snapshot. Clearing chat, starting a recording, app startup and normal termination delete the snapshot and reset its generation. An abnormal exit can leave the last snapshot until startup; it is never proof of an active app. Already delivered context cannot be revoked. Chat is not exported by the currently installed old app and native installation must wait until recording is finished. The MCP server itself never writes or deletes meeting data.

This guide describes source changes required by the current bridge. Its CLI calls were checked against upstream Paseo source and documentation. A complete deployment on an independent upstream Paseo installation has not been tested.

## Choose the parts you need

| Capability | Required components |
| --- | --- |
| Local transcription and notes | Mitschrift on the Mac. Disable `structureEnabled` to skip remote cleanup. |
| Transcript cleanup | SSH, Python 3, and an authenticated Codex CLI. No vault pointer is needed. |
| Recent-question shortcut | SSH, Python 3, and an authenticated Codex CLI. No vault pointer is needed. |
| Typed questions and chat | The Codex prerequisites, a vault pointer file, and a readable notes directory on the host. |
| `/analyse` | SSH, Python 3, a vault pointer file, a running PandaOS or Paseo daemon, an available provider, and an existing workspace. |

[PandaOS](https://github.com/marushan49/pandaos) is a public fork of [Paseo](https://github.com/getpaseo/paseo). You can use upstream Paseo's session CLI. The custom PandaOS tab-opening action needs separate handling, described below.

## 1. Prepare your host

Use your existing PandaOS or Paseo host. Install Python 3 and the Codex CLI there, and authenticate Codex with your account. Follow the [Paseo setup documentation](https://paseo.sh/docs) for the daemon and provider setup.

Make the Mitschrift checkout available on that host. The Mac sends JSON to `python3 /absolute/path/to/mitschrift/scripts/ask-codex.py` over SSH. Questions are passed through standard input.

On the Mac, confirm that your SSH alias works without an interactive password prompt:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 YOUR_SSH_ALIAS 'python3 --version'
```

In the Mac's `~/.config/mitschrift/config.json`, set `structureHost` to that alias. Chat and cleanup share this field and the bridge.

```json
{
  "structureHost": "YOUR_SSH_ALIAS",
  "structureEnabled": false
}
```

Merge these fields into the existing file. Enable cleanup once the bridge answers chat questions.

## 2. Adapt the Codex bridge

In the Mac's config, set `bridgeScript` to the absolute path of `scripts/ask-codex.py` **on the SSH host**.

Choose the account, model, and effort for each task in the Mac's `ai` config, described in the [configuration reference](reference.md#choose-the-ai-for-each-task). Edit [`scripts/ask-codex.py`](../scripts/ask-codex.py) on the host for the remaining paths:

| Symbol | Set it to… |
| --- | --- |
| `CODEX` | The absolute path returned by `command -v codex`. |
| `VAULT` | A text file containing the absolute path of your readable notes directory. |

`VAULT` is a pointer file, not the vault directory itself. For example, set it to `Path('/absolute/path/to/bridge/vault-path')`, then put one directory path in that file:

```text
/absolute/path/to/your/notes
```

The host-side notes directory and the Mac's `vaultPath` are separate settings. The repository contains neither your notes nor credentials. No Second Brain skill installation is required for ordinary chat; the current prompt asks Codex to read a few relevant vault notes.

The prompts name the original user and request German answers. Adapt `CONTEXT`, `SPEAKERS`, `ASKED`, `QUESTION`, `STRUCTURE`, and the analysis task text for your identity and language. To change the built-in defaults for every Mac, edit `DEFAULTS` and `OLLAMA_DEFAULT`.

The bridge passes `--ignore-user-config`, sets `CODEX_HOME` from the configured account, and invokes Codex with a read-only sandbox. That sandbox does not confine reads to the vault; the prompt supplies that scope. Check your installed CLI's flags with `codex exec --help`.

The pointer file must exist for typed questions and `/analyse`. Typed questions also require its target directory as the Codex working directory. Analysis reads the pointer file but uses the configured agent workspace. The recent-question shortcut uses a temporary directory and needs neither the pointer nor its target.

Config changes take effect after relaunching Mitschrift. Python bridge changes take effect on the next request.

## 3. Connect independent analysis sessions

Skip this section if you only need ordinary chat. Normal questions invoke Codex directly and never call the PandaOS or Paseo CLI.

On the SSH host, find your installed CLI:

```bash
command -v paseo
paseo --help
paseo provider ls --json
paseo workspace ls --json
```

For PandaOS, use `pandaos` in place of `paseo`. In `scripts/ask-codex.py`, set `PANDAOS` to the absolute executable path. The variable and helper can retain their existing names when the executable is upstream `paseo`.

If you need a workspace, create one for an existing checkout on that host:

```bash
paseo workspace create --isolation local --path /absolute/path/to/checkout --title Mitschrift
paseo workspace ls --json
```

Set `ai.analysis.workspace` in the Mac's config to your workspace's ID. Do not copy the repository's workspace ID. Use the same daemon and home as your Paseo client. If necessary, set `PASEO_HOME` or `PASEO_HOST` in the host process environment; the upstream CLI treats them as alternatives.

Inspect the provider and model choices on your installation:

```bash
paseo provider models --help
paseo run --help
paseo provider diagnostic codex --json
```

Replace `codex` in the diagnostic command if your provider has another ID. Then set the analysis entry in the Mac's config:

```json
{
  "ai": {
    "analysis": { "account": "YOUR_PROVIDER_ID", "model": "YOUR_MODEL", "effort": "high", "workspace": "YOUR_WORKSPACE_ID" }
  }
}
```

`account` and `model` become `--provider account/model`, `effort` becomes `--thinking`. `codex-business` in the defaults is a custom provider ID. The bridge also passes `--mode auto`; change it in the analysis `pandaos('run', ...)` call if your provider lacks that mode. The helper adds `--json` to every call.

The bridge uses these upstream commands and response fields:

| Purpose | CLI contract |
| --- | --- |
| Find an earlier start | `ls --global --label mitschrift.analysis-request=UUID --json`, using the returned item's `id`. |
| Start independently | `run --no-wait --workspace ID ... --label KEY=VALUE --json`, using `agentId`, with `id` as a fallback. |
| Request a tab in PandaOS | `agent update ID --label pandaos.open-tab-request=TIMESTAMP --json`. The label's consumer is PandaOS-specific. |

These contracts are documented in the [Paseo CLI reference](https://paseo.sh/docs/cli.md) and implemented in the upstream [run](https://github.com/getpaseo/paseo/blob/main/packages/cli/src/commands/agent/run.ts), [list](https://github.com/getpaseo/paseo/blob/main/packages/cli/src/commands/agent/ls.ts), and [update](https://github.com/getpaseo/paseo/blob/main/packages/cli/src/commands/agent/update.ts) commands. Check your installed version's help before adapting the bridge.

## 4. Handle opening the session

With PandaOS, the existing button sends the tab-request label above. Your installation needs the corresponding PandaOS behavior to open the agent tab.

With upstream Paseo, find the analysis session in your workspace or run `paseo ls --global --json`, then open it in the client. Do not rely on the existing **Open analysis in PandaOS** button. Upstream support for that custom label has not been established. For automatic opening, adapt the `open-analysis` branch to a mechanism verified on your installed version.

## 5. Verify your installation

1. Run the SSH Python check above, then check `codex exec --help` on that host.
2. Use a short, non-sensitive test transcript. Send one ordinary question, then a follow-up. Confirm that the reply uses the new transcript and conversation context.
3. If you need image support, attach a non-sensitive image and ask a question about its contents.
4. Send one `/analyse` request. Confirm that exactly one session appears in the intended workspace and that its provider, model, and permissions match your configuration.
5. Open that session in your client. Confirm that its result remains available independently of Mitschrift.

The lookup before a repeated analysis request reduces duplicate starts but is not atomic. Simultaneous requests with the same ID can still start multiple sessions. After a timeout, inspect your sessions before retrying. Cancelling Mitschrift's wait does not stop a session already running.

Normal chat's read-only sandbox does not apply to independent analysis. Choose and verify an appropriate provider mode. The analysis-only prompt does not enforce permissions by itself.

Analysis context and attachments belong to the independent session. Their retention follows your agent host and provider. Clearing the Mitschrift chat or cancelling its wait does not delete that session.
