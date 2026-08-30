# ask ✦

A minimalist, blazing-fast CLI & TUI terminal assistant powered by Google Gemini API, written in Zig.

Designed for developers and terminal power users who want instant answers, explanations, code reviews, and commit messages without leaving the shell or breaking flow.

---

## Features

- **Blazing Fast & Real-time Streaming**: Native Zig binary with live Server-Sent Events (SSE) streaming tokens directly as they are generated.
- **Autonomous Floating TUI & Popup Mode**: Standalone interactive terminal UI with clean input editor, history cycling, slash commands, and hotkey/Rofi launcher integration.
- **Intelligent Word Wrapping & Preserved Indentation**: Output text wraps cleanly without stretching across wide monitors, preserving nested list indentation (`•`, `◦`, `1.`), blockquotes (`▎`), and full ANSI color formatting across lines.
- **Horizontal Scrolling Input Viewport**: Smooth single-line prompt editing with automatic horizontal viewport scrolling for long queries, preventing line duplication or terminal artifacts.
- **Token & Cost Tracking in USD**: Real-time execution stats in response footers showing elapsed time, token counts, and estimated cost in USD (e.g. `0.28s • 120 tokens • $0.00003`).
- **Compact Model Indicators & Smart Fallback**: Shortened model tags (`Gemini-3.5FL`, `Gemini-3.5F`, `Gemini-2.5P`, `Gemma-4-31B`) with automatic fallback support (`(F)`) when a primary model is rate-limited or busy.
- **Interactive Runner & Quick Execute**: Code snippets in output receive shortcut keys (`[ a ]`, `[ b ]`). Press `a` or `1` at the `Run ❯` prompt to load and edit the command, press `Enter` to execute immediately in your shell, press `y` to copy to clipboard, or `q` to quit. Multi-line language scripts (Python, Node, Bash, Ruby, etc.) are safely dispatched to their respective interpreters.
- **Clean Terminal Selection & Clipboard Copying**: Markdown code blocks use clean indentation with no intrusive vertical border characters (`│`), ensuring mouse drag-selection copies pure code. One-key clipboard copying via universal OSC 52 escape sequences and `wl-copy`/`xclip`.
- **Catppuccin Macchiato Aesthetic**: Rich 24-bit TrueColor terminal formatting with styled code blocks, language badges, markdown lists, headers, and execution metrics.
- **Secure Credential Storage**: Store your API key with `ask --key "YOUR_KEY"` into `~/.local/share/ask/credentials` with strict `0600` Unix permissions (`rw-------`). No plaintext API keys in general config files.
- **Stdin & Pipe Integration**: Pipe terminal output, logs, or git diffs directly into `ask`.
- **Scriptable & Raw Mode**: Use `-r` / `--raw` for plain unformatted output suitable for pipes (`ask -r "..." | wl-copy`).

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
ask "how to recursively count lines of code in zig"
```

---

## Practical Use Cases & Examples

### 1. Quick Terminal Lookup
```bash
ask "how to find and delete empty directories in linux"
ask "explain the difference between tcp and udp in 2 sentences"
```

### 2. Piped Input & Context Analysis
```bash
# Generate a git commit message from staged changes
git diff --staged | ask "write a concise conventional commit message"

# Analyze a panic or error log
cat crash.log | ask "explain what caused this panic and suggest a fix"

# Review code before commit
git diff HEAD~1 | ask "review this diff for potential bugs or security risks"
```

### 3. Model Override & Fallback
```bash
# Use Gemini 2.5 Pro for deep reasoning and architecture design
ask -m gemini-2.5-pro "design a clean SQL database schema for an e-commerce order system"

# Disable automatic fallback if you strictly want only the specified model
ask --no-fallback -m gemini-3.5-flash "quick query"
```

### 4. Raw Output for Shell Scripting & Clipboard
```bash
# Copy directly to clipboard
ask -r "regex for validating IPv4 address" | wl-copy

# Save script output to a file
ask -r "write a bash script to backup /var/log daily" > backup.sh
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

## Desktop & Window Manager Integration

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
| `-m, --model <name>` | Override model for query (e.g. `gemini-3.5-flash-lite`, `gemini-3.5-flash`, `gemini-2.5-pro`) |
| `--fallback` | Enable automatic model fallback if model is busy/rate-limited (default) |
| `--no-fallback` | Disable fallback, fail if requested model fails |
| `-s, --stream` | Stream tokens live in real-time |
| `--no-stream` | Wait for full response and render formatted markdown (default) |
| `-t, --tui` | Force launch interactive TUI session |
| `-r, --raw` | Output plain text without ANSI escape codes or boxes |
| `-c, --config` | Display config paths, credential status, and active settings |
| `-h, --help` | Display help screen |
| `-v, --version` | Display version information |

---

## Configuration & Storage

- **Configuration File:** `$XDG_CONFIG_HOME/ask/config.json` (defaults to `~/.config/ask/config.json`)
  ```json
  {
    "model": "gemini-3.5-flash-lite",
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

