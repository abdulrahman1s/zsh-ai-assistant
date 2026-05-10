# ZSH AI Assistant

A zsh function that turns natural-language descriptions into shell commands using Gemini, OpenAI, or Claude. You see every command before it runs.

```
? find files larger than 1GB
gemini ▸ gemini-3-flash-preview ▸ fast
find . -type f -size +1G
Run? [y/n/e/r/?]
```

`?` is fast mode. `??` is smart mode (reasoning/thinking enabled). Failed commands feed back into the next retry. You can refine, edit, or re-run any candidate.

---

## Features

- **Three providers, one interface.** Gemini, OpenAI, and Anthropic are all supported. Auto-detects from whichever API key you have set.
- **Fast and smart modes.** `?` for low-reasoning, sub-second answers. `??` for extended-thinking on harder asks ("design a one-liner to dedupe by hash and keep newest").
- **Confirm-before-run.** Every generated command is shown and requires `y` to execute. Default action on plain Enter is decline.
- **Edit before run.** Press `e` at the prompt to drop into zsh's line editor (`vared`) and tweak the command in place. Edits are persisted to cache so the next identical query returns your fix.
- **Refine on demand.** Press `r` to re-prompt the model with a follow-up directive ("case-insensitive", "exclude node_modules", "do it with ripgrep instead") while preserving the original intent.
- **Failure-aware retry.** If a command fails, a bare `?` within 10 minutes replays the *original intent* plus the last 3 failed attempts (each with their stderr) so the model can fix what broke without re-cycling through approaches it already tried.
- **Stdin context.** Anything piped in is included as context. `git status | ? what should I do`, `cat err.log | ? why is this failing`.
- **Project context auto-injection.** Probes the cwd for git branch, language manifests (`Cargo.toml`, `package.json`, `pyproject.toml`, `go.mod`, etc.) and build tooling (`flake.nix`, `Makefile`, `justfile`, `Dockerfile`, etc.) and tells the model. So "run the tests" picks the right runner; "format this" picks the right formatter.
- **Cross-distro by default.** The system prompt auto-adjusts to your OS at runtime — package manager (`apt`, `dnf`, `pacman`, `apk`, `zypper`, `xbps`, `emerge`, `brew`, `pkg`, or NixOS-declarative), clipboard tool (Wayland / X11 / macOS / none), and BSD-vs-GNU userland flag conventions are all detected. Tested on Debian-, RHEL-, Arch-, Alpine-, openSUSE-, Void-, Gentoo-family Linuxes plus NixOS, FreeBSD, and macOS.
- **Why-comments.** `-e/--explain` appends a `# why: …` shell comment so you actually learn what the flags do. Stripped from history and from re-edits so up-arrow gives a clean command.
- **Local response cache.** Identical queries return instantly from `~/.cache/ask/` instead of round-tripping the API. Cache key includes provider, model, mode, system prompt, and project context — so different stacks/branches cache separately.
- **Live streaming with typewriter pacing.** Output streams as the model produces it, paced for visual consistency between fast and smart modes.
- **Hardened against API-key leaks.** `xtrace`/`verbose` disabled inside the function. Keys passed via headers, never URLs. Re-declared `local` doesn't dump request bodies on stdout.
- **Safety hard-stops.** The system prompt refuses unguarded `rm -rf /`, `dd` to system disks, fork bombs, pipe-to-shell from URLs, etc — but only when the user *didn't* explicitly name the path. `rm -rf /tmp/build` is fine; `rm -rf $X/` where `$X` may be empty isn't.

---

## Requirements

- **zsh** 5.x or newer (the function uses `vared`, `zselect`, `setopt LOCAL_OPTIONS`, parameter-expansion features specific to zsh — it will not run in bash).
- **curl** with HTTP/2 support (any modern build).
- **jq** 1.6+ (for request body assembly and SSE stream parsing).
- **coreutils** — `mktemp`, `sha256sum`, `head`, `tail`, `cut`, `tr`, `find`, `mv`, `rm`, `cat`. Standard everywhere.
- An **API key** for at least one of: Google Gemini, OpenAI, or Anthropic Claude.

---

## Installation

```sh
git clone https://github.com/abdulrahman1s/zsh-ai-assistant ~/.config/ask
echo 'source ~/.config/ask/ask.zsh' >> ~/.zshrc
exec zsh
```

Or source it from wherever you keep your dotfiles. The file is self-contained — no other files are required.

### API keys

Set at least one of these in your shell environment (`~/.zshrc`, `~/.zshenv`, or your secrets file of choice):

```sh
export GEMINI_API_KEY="..."        # https://aistudio.google.com/apikey
export ANTHROPIC_API_KEY="..."     # https://console.anthropic.com/settings/keys
export OPENAI_API_KEY="..."        # https://platform.openai.com/api-keys
```

Auto-detect order is `gemini > claude > openai` — set whichever you want as the default first, or pin it explicitly with `export ASK_PROVIDER=claude`.

---

## Usage

### Basic

```sh
? find rust files modified this week
?? design a one-liner to dedupe lines by hash, keep newest
? -c port-forward 8080 to my staging cluster
? -o -m gpt-5.4 convert all png files in this dir to webp
```

`?` is fast mode; `??` is smart mode (extended thinking enabled). Smart mode is slower and pricier but handles harder asks ("design a one-liner that…", "build a pipeline that…") much better.

### Stdin context

Anything piped in is treated as labelled context for the model — useful for "what does this mean", "what should I do with this", or "what's wrong here" workflows.

```sh
git status | ? what should I do
git diff --stat | ? what does this PR look like
git log --oneline -20 | ? summarise what changed recently

cat err.log | ? why is this failing
cargo build 2>&1 | ? explain this rust error
journalctl -u nginx -n 50 --no-pager | ? what's wrong with nginx

ps aux --sort=-%mem | head -20 | ? which of these should I kill
df -h | ? which mount is almost full
docker ps -a | ? clean up the stopped containers
kubectl get pods -A | ? which pod is unhealthy and why

ls -la | ? rename these files to lowercase
find . -name '*.log' | ? group these by directory and summarise sizes
```

Stdin is capped at **32 KB**. The first 32 KB of a long log is usually more diagnostic than the last (the start has the original error; the tail just repeats it). If you specifically need the tail, pipe through `tail` first:

```sh
tail -c 32k server.log | ? what's the last error here
```

You can combine stdin context with explicit intent — the model gets both:

```sh
git status | ? -e prepare a clean-up commit
# → git add -A && git commit -m "chore: clean up" # why: -A stages new+modified+deleted in one shot
```

### Refine — press `r` at the prompt

When the candidate is close but not quite right, press `r` and type a follow-up directive. The model gets the original intent + the previous candidate + your refinement, and tries again.

```
$ ? find duplicate files
gemini ▸ gemini-3-flash-preview ▸ fast
find . -type f -exec md5sum {} + | sort | uniq -d -w 32

Run? [y/n/e/r/?] r
refine: case-insensitive paths
gemini ▸ gemini-3-flash-preview ▸ fast
find . -type f -exec md5sum {} + | sort -f | uniq -d -w 32

Run? [y/n/e/r/?] r
refine: also exclude .git directory
gemini ▸ gemini-3-flash-preview ▸ fast
find . -path ./.git -prune -o -type f -exec md5sum {} + | sort -f | uniq -d -w 32

Run? [y/n/e/r/?] y
```

Refines stack — each `r` carries the prior candidate forward, so iterating "case-insensitive → exclude .git → also exclude node_modules" is natural.

Refines are not cached. Each one costs an API round-trip. If you want to commit a tweak permanently for future identical queries, use `e` instead — `e` edits in place and saves the result to cache.

More refine examples:

```
$ ? show ports in use
sudo ss -tulpn
[r] refine: only IPv6 → sudo ss -tulpn -6
[r] refine: skip ssh → sudo ss -tulpn -6 | grep -v ':22 '

$ ? compress this directory
tar -czf out.tar.gz .
[r] refine: use zstd, max compression → tar --zstd -cf out.tar.zst -I 'zstd -19' .
[r] refine: exclude node_modules and .git → tar --zstd -cf out.tar.zst --exclude='./node_modules' --exclude='./.git' -I 'zstd -19' .

$ ? convert all png to webp
for f in *.png; do cwebp "$f" -o "${f%.png}.webp"; done
[r] refine: lossless and quality 100 → for f in *.png; do cwebp -lossless -q 100 "$f" -o "${f%.png}.webp"; done
[r] refine: do it in parallel → find . -maxdepth 1 -name '*.png' -print0 | xargs -0 -P "$(nproc)" -I{} cwebp -lossless -q 100 {} -o {}.webp
```

### Retry after failure — just press `?` again

When a command fails — whether generated by `?` or typed by hand — a bare `?` within 10 minutes replays the *original intent* plus the last 3 attempts (each with their stderr) so the model can fix what actually broke instead of restarting from scratch.

```
$ ? extract this archive
gemini ▸ gemini-3-flash-preview ▸ fast
tar -xzf archive.tar.bz2
Run? [y/n/e/r/?] y
gzip: stdin: not in gzip format
tar: Child returned status 1
tar: Error is not recoverable: exiting now

$ ?
retrying: extract this archive
gemini ▸ gemini-3-flash-preview ▸ fast
tar -xjf archive.tar.bz2

Run? [y/n/e/r/?] y
```

The retry buffer holds up to 3 attempts before pruning. After a successful run, the buffer is cleared. After 10 minutes of no failures, it auto-expires — so an old broken command from earlier in the day doesn't pollute a fresh `?`.

More retry examples:

```
$ ? install ripgrep
sudo apt install ripgrep
[run] → E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
$ ?
retrying: install ripgrep
sudo apt-get update && sudo apt-get install -y ripgrep
# (model sees the permission error didn't include sudo issue but a lock issue;
#  on second look it might also realise apt was already wrapped in sudo and
#  point to a held lock — depends on stderr.)

$ ? find python files modified this week, replace 'foo' with 'bar'
find . -name '*.py' -mtime -7 -exec sed -i 's/foo/bar/g'
[run] → find: missing argument to `-exec'
$ ?
retrying: find python files modified this week, replace 'foo' with 'bar'
find . -name '*.py' -mtime -7 -exec sed -i 's/foo/bar/g' {} +

$ ? port-forward redis to localhost
kubectl port-forward svc/redis 6379:6379
[run] → error: services "redis" not found
$ ?
retrying: port-forward redis to localhost
kubectl port-forward -n cache svc/redis-master 6379:6379
# (the model picks a different namespace + service name based on the error)
```

If retries are heading the wrong direction, type a normal `?` query to start over — the failure buffer is rebuilt from whatever attempt sequence comes next.

### Edit before running — press `e`

Drops you into zsh's line editor on the candidate command. Tweak a path, swap a flag, then Enter to run. **Edits are persisted to cache** — next time you ask the same question, you get your edit, not the model's original.

```
$ ? show top memory hogs
ps aux --sort=-%mem | head -10
Run? [y/n/e/r/?] e
ps aux --sort=-%mem | head -20    ← your edit here
```

### Explain mode

`-e` adds a one-line `# why:` comment explaining what the flags do. The comment is stripped before the command is pushed to history, so up-arrow gives a clean version.

```sh
? -e show all open ports with the owning process
# → sudo ss -tulpn # why: -t tcp, -u udp, -l listen-only, -p process, -n numeric

? -e find files modified in the last week
# → find . -type f -mtime -7 # why: -mtime takes days; negative means newer-than

? -e copy current branch name to clipboard
# → git rev-parse --abbrev-ref HEAD | tr -d '\n' | wl-copy # why: tr -d strips trailing newline so paste is clean
```

### Provider selection

```sh
? -g find rust files                          # Gemini
? -c port-forward 8080 to staging              # Claude
? -o convert these png to webp                 # OpenAI
? -m claude-opus-4-1 -c plan a migration       # Override model
? -p openai -m gpt-5.4-pro design a pipeline   # Long-form provider flag
```

Auto-detect order is `gemini > claude > openai`. Pin a default with `export ASK_PROVIDER=claude` in your `.zshrc`.

### The confirm prompt

```
Run? [y/n/e/r/?]
```

| Key   | Action                                                         |
|-------|----------------------------------------------------------------|
| `y`   | Run the command                                                |
| `n`   | Decline (default — plain Enter also works)                     |
| `e`   | Edit the command in `vared` before running                     |
| `r`   | Refine: rewrite with a follow-up directive                     |
| `?`   | Show this help inline, then re-prompt                          |

### Flags

```
Provider:
  -g, --gemini          Google Gemini      (env: GEMINI_API_KEY)
  -o, --openai          OpenAI             (env: OPENAI_API_KEY)
  -c, --claude          Anthropic Claude   (env: ANTHROPIC_API_KEY)
  -p, --provider PROV   Same as the long-form flags above

Mode:
  -s, --smart           Reasoning/thinking enabled — slower, more accurate
  -f, --fast            Minimal reasoning — fast and cheap (default)

Cache:
  --no-cache            Skip the cache for this call (no read, no write)
  --clear-cache         Wipe ~/.cache/ask and exit

Context:
  --no-context          Skip cwd-aware project-context injection

Other:
  -m, --model MODEL     Override the model name for the chosen provider
  -e, --explain         Append a `# why: …` comment explaining the command
  -d, --debug           Print request URL/body and raw response to stderr
  -h, --help            Show help
```

### Environment variables

| Variable             | Meaning                                                  |
|----------------------|----------------------------------------------------------|
| `ASK_PROVIDER`       | Default provider (`gemini`, `claude`, `openai`)          |
| `ASK_MODE`           | Default mode (`fast`, `smart`)                           |
| `GEMINI_MODEL`       | Override Gemini model                                    |
| `OPENAI_MODEL`       | Override OpenAI model                                    |
| `ANTHROPIC_MODEL`    | Override Claude model                                    |
| `XDG_CACHE_HOME`     | Cache root (defaults to `~/.cache`)                      |

---

## How it works

1. **Parse** flags and stdin into a task description.
2. **Probe** the cwd for git branch, language manifests, and build tooling. Wrap as `<cwd>git main | lang rust | tools nix</cwd>` and prepend to the task.
3. **Look up** a sha256 cache key over `(provider, model, mode, system prompt, task)`. If hit, skip to step 6.
4. **Stream** the request to the chosen provider's SSE endpoint. Show a spinner until the first delta lands; then typewrite the response.
5. **Strip** stray markdown fences, save the cleaned command to cache.
6. **Confirm** with `y/n/e/r`. On `e`, drop into `vared`. On `r`, rebuild the task with the original intent + previous candidate + refinement directive, loop back to step 3.
7. **Run** via `eval` with stderr captured to a tempfile. On failure, write a JSONL entry to `.last_attempts.jsonl` (capped at 3 entries, last 4KB of stderr each) so a subsequent bare `?` can replay the failure as context.

---

## Cross-platform support

The system prompt **auto-adjusts** to your environment at runtime. On every call, it probes:

- **OS** — reads `/etc/os-release` on Linux for `ID`, `ID_LIKE`, `PRETTY_NAME`; checks `$OSTYPE` for macOS and the BSDs.
- **Package manager** — picks the right install command (`apt`, `dnf`, `pacman`, `apk`, `zypper`, `xbps`, `emerge`, `brew`, `pkg`) based on detected distro. NixOS gets a "don't suggest install steps; the system is declarative" rule. Unknown distros fall back to "pick guaranteed-available POSIX tools, don't guess at install commands".
- **Clipboard** — Wayland (`wl-copy`/`wl-paste`) if `$WAYLAND_DISPLAY` is set and the tools are installed, X11 (`xclip` or `xsel`) if `$DISPLAY` is set, macOS pasteboard (`pbcopy`/`pbpaste`) on Darwin, otherwise nothing — model is told to skip clipboard commands when none is available.

**Detected families:**

| Family               | Package manager   | Examples                                      |
|----------------------|-------------------|-----------------------------------------------|
| NixOS                | (declarative)     | NixOS                                         |
| Debian               | `apt`             | Ubuntu, Debian, Mint, Pop!\_OS, Kali, Raspbian |
| Fedora / RHEL        | `dnf`             | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Amazon Linux |
| Arch                 | `pacman`          | Arch, Manjaro, EndeavourOS, Garuda, Artix, CachyOS |
| Alpine               | `apk`             | Alpine                                        |
| openSUSE             | `zypper`          | openSUSE, SLES                                |
| Void                 | `xbps-install`    | Void                                          |
| Gentoo               | `emerge`          | Gentoo                                        |
| macOS                | `brew` (if installed) | macOS                                     |
| BSD                  | `pkg`             | FreeBSD, OpenBSD, NetBSD, DragonFly           |

To verify what the model sees on your machine:

```sh
source ask.zsh
_ask_env
# os_pretty       Arch Linux
# os_kind         Linux
# pkg_rule        This is an Arch-family distro — when a tool is genuinely missing, ...
# clipboard_line  Wayland clipboard — use 'wl-copy' to copy, 'wl-paste' to paste; never xclip or xsel.
# clipboard_tools wl-copy, wl-paste (Wayland)
```

If your distro isn't in the list above and you'd like first-class support, open a PR adding a case to `_ask_env` — it's one line per ID in the case-statement chain.

---

## Caching

Responses are cached in `${XDG_CACHE_HOME:-~/.cache}/ask/` keyed by sha256 of `(provider, model, mode, system_prompt, task_with_context)`. Identical queries return instantly. Edits made via the `e` key overwrite the cached entry, so your manual fix wins next time.

To bypass for a single call: `? --no-cache <query>`.
To wipe everything: `? --clear-cache`.

---

## Safety

The system prompt enforces hard-stop refusals for unambiguously dangerous patterns: recursive deletion of system roots, whole-disk writes (`dd`, `mkfs`, `wipefs`) to unnamed devices, fork bombs, pipe-to-shell from arbitrary URLs, mass `chmod 777`, disabling firewalls, etc. The model emits `echo 'REFUSED: <reason>'` instead of the literal command in those cases.

The carveout: if you **explicitly name** a specific path or device — `rm -rf /tmp/build`, `wipe my USB at /dev/sdc` — it's generated normally. You took responsibility by naming it.

This is a defense-in-depth layer, not a guarantee. **You** see every command before it runs and **you** press y. Read what's on the line.

---

## Privacy

- Prompts and stdin context are sent to whichever provider you selected. Don't pipe secrets you don't want logged by your provider's API endpoint.
- API keys are passed via HTTP headers, never URLs. `xtrace`, `verbose`, and zsh's typeset-echo are disabled inside the function — keys won't leak to your terminal even if you have shell tracing on.
- Stdin input is capped at 32 KB (head, not tail — start of a log/diff is more diagnostic than the end).
- Debug mode (`-d`) prints the full request body to stderr, with API keys redacted from any URL.

---

## License

MIT.
