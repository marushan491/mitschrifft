# Connect Mitschrift to PandaOS or Paseo

Set up the optional assistant on your SSH host. Local recording, transcription, and Markdown notes work without this integration.

This guide describes source changes required by the current bridge. Its CLI calls were checked against upstream Paseo source and documentation. A complete deployment on an independent upstream Paseo installation has not been tested.

## Choose the parts you need

| Capability | Required components |
| --- | --- |
| Local transcription and notes | Mitschrift on the Mac. Disable `structureEnabled` to skip Ollama cleanup. |
| Transcript cleanup | SSH access to your host, Ollama, and the configured `structureModel`. |
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

In the Mac's `~/.config/mitschrift/config.json`, set `structureHost` to that alias. Chat and Ollama cleanup share this field, even if cleanup is disabled.

```json
{
  "structureHost": "YOUR_SSH_ALIAS",
  "structureEnabled": false
}
```

Merge these fields into the existing file. If you want Ollama cleanup, enable it and set `structureModel` to a model installed on that host.

## 2. Adapt the Codex bridge

Edit [`Sources/mitschrift/Assistant.swift`](../Sources/mitschrift/Assistant.swift) in the Mac build checkout. Set `CodexAsk.script` to the absolute path of `scripts/ask-codex.py` **on the SSH host**.

Edit [`scripts/ask-codex.py`](../scripts/ask-codex.py) on the host:

| Symbol | Set it to… |
| --- | --- |
| `CODEX` | The absolute path returned by `command -v codex`. |
| `CODEX_HOME` | The Codex home containing your authenticated account. |
| `MODEL` and `EFFORT` | A model and reasoning effort available to that account. |
| `VAULT` | A text file containing the absolute path of your readable notes directory. |

`VAULT` is a pointer file, not the vault directory itself. For example, set it to `Path('/absolute/path/to/bridge/vault-path')`, then put one directory path in that file:

```text
/absolute/path/to/your/notes
```

The host-side notes directory and the Mac's `vaultPath` are separate settings. The repository contains neither your notes nor credentials. No Second Brain skill installation is required for ordinary chat; the current prompt asks Codex to read a few relevant vault notes.

The prompts name the original user and request German answers. Adapt `CONTEXT`, `SPEAKERS`, `ASKED`, `QUESTION`, and the analysis task text for your identity and language. If you change models, update the response metadata so the UI reports the actual model and account.

The bridge passes `--ignore-user-config`, uses `CODEX_HOME`, and invokes Codex with a read-only sandbox. That sandbox does not confine reads to the vault; the prompt supplies that scope. Check your installed CLI's flags with `codex exec --help`.

The pointer file must exist for typed questions and `/analyse`. Typed questions also require its target directory as the Codex working directory. Analysis reads the pointer file but uses the configured agent workspace. The recent-question shortcut uses a temporary directory and needs neither the pointer nor its target.

Rebuild the Mac app after changing `CodexAsk.script`, using [your signing identity](../README.md#build-and-install). Python bridge changes take effect on the next request.

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

Set `ANALYSIS_WORKSPACE` to your workspace's ID. Do not copy the repository's workspace ID. Use the same daemon and home as your Paseo client. If necessary, set `PASEO_HOME` or `PASEO_HOST` in the host process environment; the upstream CLI treats them as alternatives.

Inspect the provider and model choices on your installation:

```bash
paseo provider models --help
paseo run --help
paseo provider diagnostic codex --json
```

Replace `codex` in the diagnostic command if your provider has another ID. In the bridge's analysis `pandaos('run', ...)` call, replace these installation-specific arguments:

| Argument | What to choose |
| --- | --- |
| `--provider codex-business/gpt-6.1-sol` | Your available provider and model. `codex-business` is a custom provider ID. |
| `--thinking high` | A reasoning level supported by that model. |
| `--mode auto` | A mode supported by your provider. Do not assume the custom provider's `auto` mode exists upstream. |

Keep `--workspace`, `--no-wait`, `--label`, and image arguments. The helper adds `--json` to every call. Update the response text and metadata if you select a different provider or model.

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
