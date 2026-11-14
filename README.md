# ask ✦

A minimalist, blazing-fast CLI & TUI terminal assistant powered by Google Gemini API, written in Zig.

Designed for developers and terminal power users who want instant answers, explanations, code reviews, and commit messages without leaving the shell or breaking flow.

---

## Features

- **Cloud & Local LLM (`-L` / `--local`)**: Uses Google Gemini API (`Gemini 3.5 / 2.5 / Gemma 4`) by default, or connects to any local `llama-server` / OpenAI-compatible endpoint (`--local`) for 100% offline use.
- **One-Shot CLI & Interactive TUI**: Run quick unquoted queries from the shell (`ask how to...`) or launch a floating TUI session (`ask` / `--tui`) with history and slash commands (`/local`, `/model`, `/copy`, `/run`).
- **Interactive Snippet Runner**: Code blocks get hotkeys (`[ a ]`, `[ b ]`) — press `a` to edit/run commands directly in your shell or `y` to copy to clipboard (`OSC 52` / `wl-copy`).
- **Editor & Pipe Ready (`-r`, `-l`)**: Pipe `stdin` (`git diff | ask ...`) or integrate directly with editors like **Helix** using `-r` (strips UI and ` ``` ` fences) and `-l=<lang>`.
- **Terminal-Native Markdown**: Catppuccin Macchiato TrueColor theme, clean borderless code blocks for easy mouse selection, and execution stats (`time • tokens • $USD`).
- **Secure Key Storage**: Stores API keys in `~/.local/share/ask/credentials` with strict `0600` permissions.

---

## Installation

### Prerequisites
- [Zig](https://ziglang.org/download/) `0.16.x` or later.
- A free Google Gemini API key from [Google AI Studio](https://aistudio.google.com/app/apikey).

### Option 1: Install to User Bin (`~/.local/bin`) — Recommended

```bash
git clone https://github.com/your-username/ask.git
cd ask
zig build -Doptimize=ReleaseFast
mkdir -p ~/.local/bin
cp zig-out/bin/ask ~/.local/bin/
```

Ensure `~/.local/bin` is in your `PATH`. If not, add it to your shell configuration:

- **Bash / Zsh (`~/.bashrc` or `~/.zshrc`):**
  ```bash
  export PATH="$HOME/.local/bin:$PATH"
  ```
- **Fish (`~/.config/fish/config.fish`):**
  ```fish
  fish_add_path ~/.local/bin
  ```

### Option 2: System-wide Installation (`/usr/local/bin`)

```bash
sudo cp zig-out/bin/ask /usr/local/bin/
```

---

## Quickstart

### 1. Set Your Gemini API Key

Save it securely for persistent use (saved with `0600` permissions):

```bash
ask --key "AIzaSyYourSecretApiKeyHere"
```

Or set the environment variable:

```bash
export GEMINI_API_KEY="AIzaSyYourSecretApiKeyHere"
# (or export GOOGLE_API_KEY="...")
```

### 2. Ask Away!

```bash
ask how to recursively count lines of code in zig
```

---

## Practical Use Cases & Examples

### 1. Quick Terminal Lookup (No Quotes Needed)
```bash
ask how to find and delete empty directories in linux
ask explain the difference between tcp and udp in 2 sentences
```

### 2. Piped Input & Context Analysis
```bash
# Generate a git commit message from staged changes
git diff --staged | ask write a concise conventional commit message

# Analyze a panic or error log
cat crash.log | ask explain what caused this panic and suggest a fix

# Review code before commit
git diff HEAD~1 | ask review this diff for potential bugs or security risks
```

### 3. Model Override, Local LLM & Fallback
```bash
# Use Gemini 2.5 Pro for deep reasoning and architecture design
ask -m gemini-2.5-pro design a clean SQL database schema for an e-commerce order system

# Query local LLM via llama-server (http://127.0.0.1:8888)
ask --local write a fast quicksort in zig
ask -L -m qwen2.5-coder-3b-instruct explain this regex

# Disable automatic fallback if you strictly want only the specified model
ask --no-fallback -m gemini-3.5-flash quick query
```

### 4. Raw Output for Editors, Shell Scripting & Clipboard
```bash
# Copy directly to clipboard (strips markdown ``` fences automatically)
ask -r regex for validating IPv4 address | wl-copy

# Generate pure code for a specific language
ask -r -l=zig write a binary search function

# Save script output to a file
ask -r write a bash script to backup /var/log daily > backup.sh
```

### 5. Autonomous TUI & Interactive Session
Run `ask` without arguments, with `--tui`, or trigger via Sway hotkey (<kbd>Super</kbd> + <kbd>Alt</kbd> + <kbd>I</kbd>) / Rofi (<kbd>Super</kbd> + <kbd>Space</kbd> $\rightarrow$ `ask`):

```text
╭── ✦ Ask (Gemini-3.5FL) ───────────────────────────────────────────
│   Type a prompt or command (/help, /model, /copy, /clear, /stream)
│   Esc or Ctrl+D to exit  •  Up/Down history  •  Stream: off
╰───────────────────────────────────────────────────────────────────

ask ❯ How do I check open ports in Linux?

╭───────────────────────────────────────────────────────────────────
  To check all open listening ports and their processes:

  ╭── [ a ] bash ───────────────────────────────────────────────────
    sudo ss -tulpn
  ╰─────────────────────────────────────────────────────────────────

  • -t: TCP sockets
  • -u: UDP sockets
  • -l: Listening sockets
  • -p: Show process using socket
  • -n: Show numerical port numbers

╰── [ 0.28s • 85 tokens • $0.00002 ] ───────────────────────────────

  💡 Snippet: /copy a to copy, /run a to run, /copy for all text
```

**In-TUI Slash Commands & Controls:**
- `/help`, `/?` — Quick reference card with commands and shortcuts
- `/model <name>`, `/models` — View and switch AI models on the fly (`gemini-3.5-flash-lite`, `gemini-3.5-flash`, `gemini-2.5-pro`, etc.)
- `/stream` — Toggle real-time token streaming
- `/copy`, `/y` — Copy the last response directly to clipboard
- `/copy <key>` — Copy specific snippet (e.g. `/copy a`)
- `/run <key>` — Execute snippet in terminal (e.g. `/run a`)
- `/clear`, `/cls`, `Ctrl+L` — Clear screen and reset header
- `/history` — List past queries from the current session
- `/exit`, `/quit`, `q`, `Esc` — Close popup window immediately
- **Keyboard navigation:** Smooth line editing with horizontal scrolling, Home/End, Backspace, Delete, Ctrl+U/W, and Up/Down history browsing.

---

## Desktop, Editor & Window Manager Integration

### Helix Editor (`~/.config/helix/config.toml`)
Integrate `ask` directly into Helix using `-r` (raw output without Markdown ` ``` ` fences) and `-l=%{language}` (automatic buffer language detection):

```toml
[keys.normal.space]
q = "@:insert-output ask -r -l=%{language} "
Q = "@|ask -r -l=%{language} "

[keys.select.space]
q = "@|ask -r -l=%{language} "
```

- **Insert code at cursor (<kbd>Space</kbd> + <kbd>q</kbd> in Normal mode):** Opens `:insert-output ask -r -l=%{language} `. Type your prompt without quotes and press <kbd>Enter</kbd> to insert clean code directly at the cursor.
- **Transform or analyze selected code (<kbd>Space</kbd> + <kbd>q</kbd> in Select mode, or <kbd>Space</kbd> + <kbd>Shift</kbd> + <kbd>Q</kbd> in Normal mode):** Opens `Shell pipe: ask -r -l=%{language} `. Pipes the active selection into `ask` as context along with your prompt and replaces the selection with the result.

### Sway / Wayland Hotkey Popup
Add floating window rules and a hotkey to your Sway config (`~/.config/sway/config.d/99-ask-tui.conf`):

```sway
for_window [app_id="(?i)ask-tui"] floating enable, border pixel 2, resize set width 52 ppt height 58 ppt, move position center
bindsym --to-code $mod+Mod1+i exec ~/.local/bin/ask-popup.sh
```

### Rofi Application Launcher
`ask` includes a `.desktop` file (`~/.local/share/applications/ask.desktop`) allowing you to launch the TUI popup directly from **Rofi** (<kbd>Super</kbd> + <kbd>Space</kbd> or <kbd>Super</kbd> + <kbd>D</kbd> $\rightarrow$ type `ask` $\rightarrow$ <kbd>Enter</kbd>).

---

## Command-Line Options

| Option | Description |
| :--- | :--- |
| `-k, --key <api-key>` | Save Gemini API key securely to credentials file (`0600`) |
| `--clear`, `--reset` | Delete stored credentials and reset configuration |
| `-L, --local` | Use local LLM server (`llama-server` / OpenAI `/v1/chat/completions`) |
| `--no-local`, `--cloud` | Force Google Gemini API mode (default) |
| `--local-url <url>` | Override local LLM server URL (default: `http://127.0.0.1:8888`) |
| `-m, --model <name>` | Override model for query (cloud Gemini model or local model with `--local`) |
| `-l, --lang <lang>` | Specify target language / filetype context (e.g. `-l=zig`, `-l=%{language}`) |
| `--fallback` | Enable automatic model fallback if model is busy/rate-limited (default) |
| `--no-fallback` | Disable fallback, fail if requested model fails |
| `-s, --stream` | Stream tokens live in real-time |
| `--no-stream` | Wait for full response and render formatted markdown (default) |
| `-t, --tui` | Force launch interactive TUI session |
| `-r, --raw` | Output clean plain text/code without ANSI styling or markdown ` ``` ` fences |
| `-c, --config` | Display config paths, credential status, and active settings |
| `-h, --help` | Display help screen |
| `-v, --version` | Display version information |

---

## Configuration & Storage

- **Configuration File:** `$XDG_CONFIG_HOME/ask/config.json` (defaults to `~/.config/ask/config.json`)
  ```json
  {
    "model": "gemini-3.5-flash-lite",
    "local": false,
    "local_url": "http://127.0.0.1:8888",
    "local_model": "~/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf",
    "system_instruction": "You are a lightning-fast CLI assistant. Provide ultra-concise, direct answers. Give immediate commands or code without preamble, conversational filler, or greetings.",
    "temperature": 0.2,
    "thinking_budget": 0,
    "theme": "catppuccin",
    "stream": false,
    "fallback": true
  }
  ```
- **Credentials File:** `$XDG_DATA_HOME/ask/credentials` (defaults to `~/.local/share/ask/credentials`, permission `-rw-------`)
- **Environment Variables Supported:** `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`.

