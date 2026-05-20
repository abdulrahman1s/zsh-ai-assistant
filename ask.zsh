# AI shell-command generator: `? find files larger than 1GB`
# Aliased to `?` in shell.nix (with noglob, since ? is a zsh glob char).
# Supports Gemini, OpenAI, Claude, and local Ollama. Set one of:
#   GEMINI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY / OLLAMA_MODEL
# Pick provider with -g / -o / -c / -l, override model with -m. See `? -h`.

# Typewriter replay of a growing file. $1 = file, $2 = writer pid
# (empty or dead → drain-only). zselect gives non-forking sleep so
# 10ms/char doesn't burn 100 forks/sec. Honours $cancelled from
# caller (dynamic scope) to bail fast on Ctrl+C.
_ask_typewriter() {
  zmodload -F zsh/zselect b:zselect 2>/dev/null
  local file=$1 pid=$2 last=0 i content
  while [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; do
    (( cancelled )) && return
    content=$(< "$file")
    if (( ${#content} > last )); then
      for (( i = last; i < ${#content}; i++ )); do
        (( cancelled )) && return
        printf '%s' "${content:$i:1}"
        zselect -t 1
      done
      last=${#content}
    else
      zselect -t 2
    fi
  done
  (( cancelled )) && return
  content=$(< "$file")
  if (( ${#content} > last )); then
    for (( i = last; i < ${#content}; i++ )); do
      (( cancelled )) && return
      printf '%s' "${content:$i:1}"
      zselect -t 1
    done
  fi
}

# Probe the cwd for project signals — git branch + language manifests +
# build/test tooling — and emit a single-line context string. Lets the
# model disambiguate ambiguous queries: "run the tests" picks the right
# runner when it knows the stack; "format this" picks the right tool;
# "what changed" knows it's a git repo. Each probe is a stat or one
# cheap git invocation; total overhead is well under 10ms for typical
# repos. Returns empty when cwd has no detectable project signal (e.g.
# a plain $HOME), so non-project shells stay context-free.
_ask_context() {
  local -a hints langs tools
  local branch

  # Branch only — `git status` would be the more informative probe but
  # walks the working tree on every call (slow on big repos). Branch
  # tells the model "git repo, on X" which covers the bulk of the
  # disambiguation value; dirty/untracked status can be added later if
  # workflows demand it.
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
      || branch=$(git rev-parse --short HEAD 2>/dev/null)
    [[ -n "$branch" ]] && hints+=("git ${branch}")
  fi

  # Language manifests — presence of a manifest is a strong signal even
  # if it's stale, because it tells the model what tools the user
  # *expects* (cargo, npm, pytest, etc.). Multiple langs are possible
  # (polyglot repos); join them all.
  [[ -f Cargo.toml ]] && langs+=(rust)
  [[ -f package.json ]] && langs+=(node)
  [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]] && langs+=(python)
  [[ -f go.mod ]] && langs+=(go)
  [[ -f Gemfile ]] && langs+=(ruby)
  [[ -f pom.xml || -f build.gradle || -f build.gradle.kts ]] && langs+=(jvm)
  [[ -f composer.json ]] && langs+=(php)
  [[ -f mix.exs ]] && langs+=(elixir)
  [[ -f deno.json || -f deno.jsonc ]] && langs+=(deno)
  (( ${#langs} )) && hints+=("lang ${(j:,:)langs}")

  # Build/runner tooling. Nix is high-signal on this NixOS host —
  # tells the model "shell.nix exists, this is reproducible-env land".
  [[ -f flake.nix || -f shell.nix || -f default.nix ]] && tools+=(nix)
  [[ -f Makefile || -f makefile ]] && tools+=(make)
  [[ -f justfile || -f Justfile ]] && tools+=(just)
  [[ -f docker-compose.yml || -f docker-compose.yaml || -f compose.yaml ]] && tools+=(compose)
  [[ -f Dockerfile ]] && tools+=(docker)
  [[ -d .github/workflows ]] && tools+=(gh-actions)
  (( ${#tools} )) && hints+=("tools ${(j:,:)tools}")

  (( ${#hints} == 0 )) && return 0
  # `${(j: | :)arr}` joins with " | " — a visually obvious separator
  # the model can lex without confusing it with command syntax.
  printf '%s' "${(j: | :)hints}"
}

# Walk up from $PWD looking for the nearest .askrc — same hierarchy
# rule as git's .gitignore or direnv's .envrc. Per-project defaults
# override env vars but lose to explicit CLI flags. Outputs the path
# of the first .askrc found, or nothing.
_ask_find_askrc() {
  local dir=$PWD
  while [[ -n "$dir" && "$dir" != / ]]; do
    if [[ -f "$dir/.askrc" ]]; then
      printf '%s' "$dir/.askrc"
      return 0
    fi
    dir=${dir:h}
  done
  [[ -f /.askrc ]] && { printf '%s' /.askrc; return 0; }
  return 1
}

# Parse a .askrc file. Format:
#   key=value                # one per line, # comments and blanks ok
#   ---                      # everything after this is appended to
#   free-form prompt text    # the system prompt verbatim
# Recognised keys: provider, mode, model. Only sets the matching
# caller-scope variable if it's currently empty, so CLI flags still
# win. The free-form section is appended to $askrc_prompt.
# Sourcing the file would be simpler but lets a stray $(rm -rf ~)
# run with the user's privileges; key=value parsing is safer.
_ask_load_askrc() {
  local file=$1
  local in_prompt=0 line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_prompt )); then
      askrc_prompt+="$line"$'\n'
      continue
    fi
    if [[ "$line" == "---" ]]; then
      in_prompt=1
      continue
    fi
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k// /}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$k" in
      provider) [[ -z "$provider" ]] && provider="$v" ;;
      mode)     [[ -z "$mode"     ]] && mode="$v" ;;
      model)    [[ -z "$model"    ]] && model="$v" ;;
    esac
  done < "$file"
  # Trim trailing blank line that `read` accumulates from the loop.
  askrc_prompt="${askrc_prompt%$'\n'}"
}

# Atomic write via temp + rename: $1 = destination, content from stdin.
# Used for retry-state files so concurrent ? calls or SIGINT mid-write
# can't tear them. rename(2) is atomic within a filesystem. Returns 0
# on success, 1 on failure (so callers can detect a torn write).
_ask_save() {
  local target=$1 tmp
  tmp=$(mktemp "$target.XXXXXX") || return 1
  if cat > "$tmp" && mv -f -- "$tmp" "$target"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

_ask_help() {
  cat <<'EOF'
Usage: ? [OPTIONS] <description>

Provider flags (default: auto-detect from API keys; override with $ASK_PROVIDER):
  -g, --gemini          Google Gemini      (env: GEMINI_API_KEY,    model: gemini-3.5-flash)
  -o, --openai          OpenAI             (env: OPENAI_API_KEY,    model: gpt-5.4-mini)
  -c, --claude          Anthropic Claude   (env: ANTHROPIC_API_KEY, model: claude-sonnet-4-6)
  -l, --ollama          Local Ollama       (env: OLLAMA_MODEL,      model: first installed)
  -p, --provider PROV   Same as the long form of the flags above

Mode flags (default: fast; override with $ASK_MODE):
  -s, --smart           High reasoning/thinking — slower, more accurate
  -f, --fast            Minimal reasoning — fast and cheap (default)

Cache:
  --no-cache            Skip the cache for this call (no read, no write)
  --clear-cache         Wipe ~/.cache/ask and exit

Context:
  --no-context          Skip cwd-aware context (git branch, language
                        manifests, build/test tooling) auto-injection.
                        On by default — gives the model project signals
                        so "run the tests" picks the right runner, etc.
  ./<path>              Include the file at <path> as labelled context.
                        Multiple allowed: `? ./a.py ./b.py compare these`.
                        First 32KB per file; non-existent paths fall
                        through as literal text.
  .askrc                Per-project defaults — searched up from cwd.
                        Format: key=value lines (provider, mode, model)
                        followed by `---` and free-form prompt text
                        appended to the system prompt. CLI flags win;
                        env vars lose.

Alternatives:
  -a, --alts N          Ask the model for N (1-8) distinct candidate
                        commands in one request, pick via fzf (or
                        numbered menu). One round-trip — cheaper and
                        faster than firing N separate calls, works on
                        every provider. Not cached.

Retry & refine:
  ?                     Bare `?` within 10 min of a failed command
                        retries it with original intent + last 3 attempts.
  [y/n/e/r]             At the confirm prompt, `r` refines the answer
                        with a follow-up directive (e.g. "case-insensitive").

Stdin:
  Anything piped to `?` is included as context, e.g.
    git status | ? what should I do
    cat err.log | ? why is this failing

Other:
  -m, --model MODEL     Override the model name for the chosen provider
  -e, --explain         Append a `# why: …` shell comment explaining the command
  -d, --debug           Print context, request JSON, and raw response to stderr
  -h, --help            Show this help

Auto-detect order: gemini > claude > openai > ollama (when a model is configured or installed).
Default model overrides: $GEMINI_MODEL, $OPENAI_MODEL, $ANTHROPIC_MODEL, $OLLAMA_MODEL.
Ollama endpoint override: $OLLAMA_HOST or $OLLAMA_BASE_URL (default: http://127.0.0.1:11434).

Aliases:
  ?    fast mode  (= ask)
  ??   smart mode (= ask --smart)

Examples:
  ? find files larger than 1GB
  ?? design a one-liner to dedupe by hash and keep newest
  ? -c port-forward 8080 to my staging cluster
  ? -o -m gpt-5.4 convert all png files in this dir to webp
  ? -l -m qwen3:8b summarize disk usage here
EOF
}

# Detect the runtime environment so the system prompt can adjust to the
# user's actual distro/clipboard/pkg-manager rather than baking in a
# hardcoded NixOS+Wayland assumption. Outputs tab-separated key/value
# pairs consumed by _ask_sys via placeholder substitution. Cheap: a
# single /etc/os-release read + a couple of `command -v` probes; total
# overhead is well under 1 ms on a warm cache.
#
# Fields:
#   os_pretty       — display name ("Arch Linux", "Ubuntu 24.04", "macOS")
#   os_kind         — Linux | Darwin | BSD | Unknown
#   pkg_rule        — package-manager rule injected into QUALITY section
#   clipboard_line  — full clipboard line in ENVIRONMENT section
#   clipboard_tools — short version for the tools sub-list
#
# Source the file and call `_ask_env` directly to see what the model
# will be told about your machine.
_ask_env() {
  local os_pretty="" os_kind="" pkg_rule=""
  local clipboard_line="" clipboard_tools=""
  local distro_id="" distro_like=""

  case "$OSTYPE" in
    darwin*)
      os_pretty="macOS"
      os_kind="Darwin"
      if command -v brew &>/dev/null; then
        pkg_rule="On macOS with Homebrew: suggest 'brew install <pkg>' only if the user explicitly asks to install something. macOS ships BSD-userland tools (find, grep, sed, awk) — they differ from GNU; use POSIX-portable flags."
      else
        pkg_rule="On macOS without Homebrew: avoid install steps. Use BSD-userland tools that ship with the OS (find, grep, sed, awk) with POSIX-portable flags — they differ from GNU."
      fi
      clipboard_line="macOS pasteboard — use 'pbcopy' to copy, 'pbpaste' to paste."
      clipboard_tools="pbcopy, pbpaste (macOS)"
      ;;
    linux*)
      os_kind="Linux"
      # /etc/os-release is the freedesktop.org standard; every modern
      # distro ships one. ID/ID_LIKE/PRETTY_NAME are the three fields
      # we care about. Strip surrounding quotes that some distros add.
      if [[ -r /etc/os-release ]]; then
        local k v
        while IFS='=' read -r k v; do
          v="${v#\"}"; v="${v%\"}"
          case "$k" in
            ID)          distro_id="$v" ;;
            ID_LIKE)     distro_like="$v" ;;
            PRETTY_NAME) os_pretty="$v" ;;
          esac
        done < /etc/os-release
      fi
      [[ -z "$os_pretty" ]] && os_pretty="Linux"

      # Match against ID first, fall back to ID_LIKE for derivatives
      # (Mint→ubuntu→debian, EndeavourOS→arch, Rocky→rhel→fedora, etc.)
      local id_chain="$distro_id $distro_like"
      case "$id_chain" in
        *nixos*)
          pkg_rule="This is NixOS — never suggest apt, brew, dnf, pacman, or pip-install steps. NixOS is declarative; if a tool may be missing, use a guaranteed alternative."
          ;;
        *ubuntu*|*debian*|*mint*|*pop*|*kali*|*raspbian*|*elementary*)
          pkg_rule="This is a Debian/Ubuntu-family distro — when a tool is genuinely missing, the install command is 'sudo apt install <pkg>'. Prefer guaranteed-available POSIX tools when possible; only suggest installs if the user explicitly asks."
          ;;
        *fedora*|*rhel*|*centos*|*rocky*|*alma*|*amzn*)
          pkg_rule="This is a Fedora/RHEL-family distro — when a tool is genuinely missing, the install command is 'sudo dnf install <pkg>'. Prefer guaranteed-available POSIX tools when possible; only suggest installs if the user explicitly asks."
          ;;
        *arch*|*manjaro*|*endeavour*|*garuda*|*artix*|*cachyos*)
          pkg_rule="This is an Arch-family distro — when a tool is genuinely missing, the install command is 'sudo pacman -S <pkg>'. Prefer guaranteed-available POSIX tools when possible; only suggest installs if the user explicitly asks."
          ;;
        *alpine*)
          pkg_rule="This is Alpine — when a tool is genuinely missing, the install command is 'sudo apk add <pkg>'. Note: Alpine uses BusyBox userland, so some GNU-specific flags are unavailable; prefer POSIX-portable ones."
          ;;
        *suse*|*sles*)
          pkg_rule="This is openSUSE/SLES — when a tool is genuinely missing, the install command is 'sudo zypper install <pkg>'. Prefer guaranteed-available POSIX tools when possible."
          ;;
        *void*)
          pkg_rule="This is Void Linux — when a tool is genuinely missing, the install command is 'sudo xbps-install -S <pkg>'."
          ;;
        *gentoo*)
          pkg_rule="This is Gentoo — install commands ('sudo emerge <pkg>') trigger slow source builds, so avoid suggesting them unless explicitly asked. Prefer guaranteed-available POSIX tools."
          ;;
        *)
          pkg_rule="Unknown Linux distribution — don't guess at package-manager commands. If a tool may be missing, use a guaranteed-available POSIX alternative instead of suggesting an install step."
          ;;
      esac

      # Clipboard: prefer Wayland when the display server is up, else
      # X11 with whichever of xclip/xsel is on PATH, else assume none
      # (headless, container, ssh session without forwarding).
      if [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-copy &>/dev/null; then
        clipboard_line="Wayland clipboard — use 'wl-copy' to copy, 'wl-paste' to paste; never xclip or xsel."
        clipboard_tools="wl-copy, wl-paste (Wayland)"
      elif [[ -n "$DISPLAY" ]] && command -v xclip &>/dev/null; then
        clipboard_line="X11 clipboard — copy with 'xclip -selection clipboard', paste with 'xclip -selection clipboard -o'; never wl-copy."
        clipboard_tools="xclip (X11)"
      elif [[ -n "$DISPLAY" ]] && command -v xsel &>/dev/null; then
        clipboard_line="X11 clipboard — copy with 'xsel --clipboard --input', paste with 'xsel --clipboard --output'; never wl-copy."
        clipboard_tools="xsel (X11)"
      else
        clipboard_line="No clipboard tool detected (headless or no display server) — avoid clipboard commands unless the user explicitly names a tool."
        clipboard_tools="none available"
      fi
      ;;
    freebsd*|openbsd*|netbsd*|dragonfly*)
      os_pretty="${OSTYPE%%[0-9.]*}"
      os_kind="BSD"
      pkg_rule="This is BSD — when a tool is genuinely missing, the install command is 'sudo pkg install <pkg>'. BSD userland differs from GNU; use POSIX-portable flags."
      if [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-copy &>/dev/null; then
        clipboard_line="Wayland clipboard — use 'wl-copy' to copy, 'wl-paste' to paste."
        clipboard_tools="wl-copy, wl-paste"
      elif [[ -n "$DISPLAY" ]] && command -v xclip &>/dev/null; then
        clipboard_line="X11 clipboard — copy with 'xclip -selection clipboard', paste with 'xclip -selection clipboard -o'."
        clipboard_tools="xclip (X11)"
      else
        clipboard_line="No clipboard tool detected — avoid clipboard commands unless the user explicitly names a tool."
        clipboard_tools="none available"
      fi
      ;;
    *)
      os_pretty="${OSTYPE:-unknown}"
      os_kind="Unknown"
      pkg_rule="Unknown OS — don't suggest install commands; pick guaranteed-available POSIX tools."
      clipboard_line="No clipboard tool assumed — avoid clipboard commands unless the user explicitly names a tool."
      clipboard_tools="none assumed"
      ;;
  esac

  # Tab-separated so values containing '=' or spaces survive the read.
  printf 'os_pretty\t%s\n'       "$os_pretty"
  printf 'os_kind\t%s\n'         "$os_kind"
  printf 'pkg_rule\t%s\n'        "$pkg_rule"
  printf 'clipboard_line\t%s\n'  "$clipboard_line"
  printf 'clipboard_tools\t%s\n' "$clipboard_tools"
}

_ask_sys() {
  # Pull runtime env values; substitute into the static prompt below.
  local os_pretty="" os_kind="" pkg_rule=""
  local clipboard_line="" clipboard_tools=""
  local k v
  while IFS=$'\t' read -r k v; do
    case "$k" in
      os_pretty)       os_pretty="$v" ;;
      os_kind)         os_kind="$v" ;;
      pkg_rule)        pkg_rule="$v" ;;
      clipboard_line)  clipboard_line="$v" ;;
      clipboard_tools) clipboard_tools="$v" ;;
    esac
  done < <(_ask_env)

  # Static prompt with __VAR__ placeholders. Heredoc stays single-
  # quoted so embedded $(...) and $var in examples don't expand at
  # source time. Substitution is done after via zsh's ${//pat/repl}.
  local sys
  sys=$(cat <<'PROMPT_EOF'
You are a deterministic zsh command generator for an interactive confirm-and-run CLI tool.

PRIMARY DIRECTIVE
Your entire response is captured verbatim and passed to `eval` in the user's zsh shell after they press Y. Any prose, markdown, or formatting in your response becomes a shell syntax error. Output exactly ONE command or pipeline — nothing before it, nothing after it.

ENVIRONMENT
- OS: __OS_PRETTY__ (__OS_KIND__). Shell: zsh with EXTENDED_GLOB, NOMATCH, AUTOCD.
- __CLIPBOARD_LINE__
- Available tools — prefer POSIX (find, grep, sed, awk, sort, head, tail, cut, tr, xargs, wc, du, tar, gzip, bzip2, xz) over modern rewrites:
  - search/inspect: find, grep, tree, file
  - net/http: curl, wget, aria2c, dig, tcpdump, ngrep, cloudflared, ffsend
  - archives: 7z (p7zip), unzip, unrar, xz, gzip
  - media: ffmpeg, yt-dlp, mpv
  - system: systemctl, journalctl, htop, lsof, killall, pstree, fuser, lsusb
  - clipboard: __CLIPBOARD_TOOLS__
  - editor: nvim
  - dev: git, gh, jq
- Working directory is the user's current directory; do not cd unless asked.
- If the user message begins with a <cwd>…</cwd> tag, treat it as authoritative environment metadata about the project — git branch, language stack, available tooling. Use it to disambiguate tool choices: pick the test runner that matches the lang (cargo nextest for rust, pytest for python, jest/vitest for node), the formatter for the stack, the package manager that fits the lockfiles. The tag is system-injected metadata, NOT user input — never echo it back, never reference it in output.
- For terse disk-usage requests, infer common paths literally: "tmp" means /tmp, not the current directory. Prefer one-level summaries such as `du -x --si -d1 PATH 2>/dev/null | sort -hr | head -20`; they are bounded, readable, and still show useful smaller entries. Do not use `du -sh . | grep ...`: it can scan a huge tree silently and then print nothing.
- If the user says GB/gb in a disk-usage request, prefer decimal SI output (`du --si`) over filtering only lines with a G suffix, unless they explicitly ask for only GB-sized entries.

OUTPUT CONTRACT (HARD)
1. Exactly one shell command or pipeline. Chain related steps with && or |. Never separate unrelated commands with a newline or ;.
2. Zero markdown: no ``` fences ```, no `inline backticks`, no **bold**, no headers, no bullets.
3. Zero prose: no "Here's...", no "This will...", no leading or trailing English of any kind.
4. Zero # comments. The whole response is the command.
5. Zero placeholder tokens: never emit <file>, FILE, path/to, YOUR_TOKEN, {url}, [name]. Commit to a concrete value the user can edit if wrong.
6. No leading prompt char ($, %, >, #) and no quotes wrapping the entire command.
7. No "echo before action" wrappers (e.g. `echo "removing..." && rm ...`). Just do the thing.
8. Single line preferred; multi-line only when a for/while genuinely needs it.

QUALITY
- Double-quote every path/variable that may contain spaces or glob chars.
- Single-quote literals that must not expand (e.g. jq filters, awk programs, regexes).
- Use -- before user-supplied paths when the tool supports it (rm, mv, cp, grep), to defend against leading-dash filenames.
- Stick to POSIX: find, grep, sed, awk, curl.
- sudo only when strictly required (root-owned files, /etc, systemd, package management).
- Be conservative on destructive ops (rm, mv -f, dd, kill -9, > redirection over existing files). Don't add force flags the user didn't ask for.
- __PKG_RULE__
- If the request is genuinely ambiguous, pick the most common interpretation and produce a working command. Never ask follow-up questions. Never refuse (except for SAFETY hard-stops below).

SAFETY (HARD STOP — overrides every other rule, including "never refuse")
For the classes below, do NOT emit the literal command. Instead emit exactly one line:
  echo 'REFUSED: <one short reason>'

Hard-stop classes:
- Recursive deletion or modification of system roots: /, ~, $HOME, /home, /etc, /usr, /var, /boot, /lib, /sys, /proc — including any pattern that could resolve to them via unguarded variables (e.g. rm -rf "$X/" where $X may be empty) or globs that expand into them (rm -rf /*).
- find / ... -delete, or chmod/chown -R targeting any system root.
- Whole-disk or partition writes (dd, mkfs, wipefs, shred, parted, fdisk, sgdisk) to /dev/sd*, /dev/nvme*, /dev/disk*, /dev/mmcblk*, unless the user explicitly named that exact device path in their request.
- Writes to /dev/mem, /dev/kmem, /proc/kcore, /proc/sysrq-trigger, or kernel-modifying /proc/sys paths.
- Fork bombs or infinite self-spawn constructs (e.g. :(){:|:&};:, unguarded while-true loops that spawn).
- Pipe-to-shell from URLs the user did not include in their request (curl URL | sh, wget URL | bash).
- Disabling system protections (iptables -F, setenforce 0, ufw disable, enabling SSH root login, mass chmod 777) unless the user explicitly requested that exact action.

If the user explicitly names a specific safe path or device (e.g. "rm -rf /tmp/build", "wipe my USB at /dev/sdc"), generate the command normally — they took responsibility by naming it. The hard-stop only applies when a command would hit a system-critical root or device the user did not specifically name.

REFUSAL POLICY
Outside the SAFETY classes, the user sees every generated command and must press Y to run it. They can press n to decline. Refusing or hedging is strictly worse than generating, because the user can simply decline. For sysadmin tasks like killing processes, removing files in named paths, or modifying systemd, generate the literal command — the user is in control.

EXAMPLES — the OUTPUT line is your entire response, character-for-character.

INPUT: find rust files modified in the last week
OUTPUT: find . -type f -name '*.rs' -mtime -7

INPUT: kill whatever is listening on port 3000
OUTPUT: kill -9 "$(lsof -t -i:3000)"

INPUT: 10 largest files under this directory
OUTPUT: du -ah . 2>/dev/null | sort -rh | head -10

INPUT: tmp gb
OUTPUT: du -x --si -d1 /tmp 2>/dev/null | sort -hr | head -20

INPUT: largest folders here
OUTPUT: du -x --si -d1 . 2>/dev/null | sort -hr | head -20

INPUT: pretty-print package.json dependencies
OUTPUT: jq '.dependencies' package.json

INPUT: follow nginx logs
OUTPUT: journalctl -u nginx -b -f --no-hostname

INPUT: extract every .tar.gz here into its own folder
OUTPUT: for f in *.tar.gz; do mkdir -p "${f%.tar.gz}" && tar -xzf "$f" -C "${f%.tar.gz}"; done

INPUT: count lines of typescript code excluding node_modules
OUTPUT: find . -type f \( -name '*.ts' -o -name '*.tsx' \) -not -path '*/node_modules/*' -exec wc -l {} +

INPUT: copy current branch name to clipboard
OUTPUT: git rev-parse --abbrev-ref HEAD | tr -d '\n' | wl-copy

INPUT: replace all tabs with 2 spaces in every js file under src
OUTPUT: find src -type f -name '*.js' -exec sed -i 's/\t/  /g' {} +

INPUT: search for TODO comments in this repo, ignoring git directory
OUTPUT: grep -rn --exclude-dir=.git 'TODO' .

INPUT: download a url to disk
OUTPUT: curl -fLo file.bin https://example.com/file.bin

ANTI-EXAMPLES — every line below is a WRONG response for "find rust files":
WRONG: ```bash\nfind . -name '*.rs'\n```                  (markdown fence)
WRONG: Here's the command: find . -name '*.rs'            (prose prefix)
WRONG: find . -name '*.rs'  # finds rust files            (trailing comment)
WRONG: find . -name '*.rs' <directory>                    (placeholder)
WRONG: `find . -name '*.rs'`                              (wrapping backticks)
WRONG: $ find . -name '*.rs'                              (leading prompt char)
WRONG: echo "searching..." && find . -name '*.rs'         (echo wrapper)
PROMPT_EOF
)

  # Substitute runtime-detected values into the static placeholders.
  # zsh ${var//pat/repl} replaces literally — no glob metas in pattern.
  sys="${sys//__OS_PRETTY__/$os_pretty}"
  sys="${sys//__OS_KIND__/$os_kind}"
  sys="${sys//__CLIPBOARD_LINE__/$clipboard_line}"
  sys="${sys//__CLIPBOARD_TOOLS__/$clipboard_tools}"
  sys="${sys//__PKG_RULE__/$pkg_rule}"

  printf '%s\n' "$sys"
}

# ──────────────────────────────────────────────────────────────────────
# Named constants. File-scope (typeset -g) so helpers can read them
# without arg-passing every value. NOT readonly — re-source during dev
# would error. The project has no readonly precedent anywhere, so this
# stays consistent with house style.
# ──────────────────────────────────────────────────────────────────────

typeset -g _ASK_STDIN_CAP=32768
typeset -g _ASK_FILE_CAP=32768
typeset -g _ASK_ATTEMPTS_KEEP=3
typeset -g _ASK_RETRY_WINDOW_MIN=10
typeset -g _ASK_ALTS_MIN=1
typeset -g _ASK_ALTS_MAX=8
typeset -g _ASK_TOKENS_FAST=500
typeset -g _ASK_TOKENS_SMART=16000
typeset -g _ASK_TOKENS_EXPLAIN_BONUS=200
typeset -g _ASK_TOKENS_PER_ALT=800
typeset -g _ASK_CLAUDE_SMART_MAX=10000
typeset -g _ASK_CLAUDE_SMART_BUDGET=5000
typeset -g _ASK_CURL_CONNECT_TIMEOUT=10
typeset -g _ASK_CURL_TIMEOUT_FAST=60
typeset -g _ASK_CURL_TIMEOUT_SMART=180
typeset -g _ASK_STDERR_CAP=4096
typeset -g _ASK_INDICATOR_MAX=80
typeset -g _ASK_SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
typeset -g _ASK_SPINNER_SLEEP=0.08

# ──────────────────────────────────────────────────────────────────────
# Error / status output. All hard-error paths flow through these so the
# format and colour stay consistent. Bold-red prefix for errors, dim
# grey for info — matches existing house style.
# ──────────────────────────────────────────────────────────────────────

_ask_die()       { printf '\033[1;31mask:\033[0m %s\n' "$*" >&2; return 1; }
_ask_warn()      { printf '\033[1;31mask:\033[0m %s\n' "$*" >&2; }
_ask_info()      { printf '\033[2m▸ %s\033[0m\n'        "$*" >&2; }
_ask_net_die()   { printf '\033[1;31mask:\033[0m network: %s\n' "$*" >&2; return 1; }
_ask_api_die()   { printf '\033[1;31mask:\033[0m api: %s\n'     "$*" >&2; return 1; }
_ask_parse_die() { printf '\033[1;31mask:\033[0m parse: %s\n'   "$*" >&2; return 1; }

_ask_debug_json() {
  local json=$1
  if ! printf '%s' "$json" | jq . 2>/dev/null; then
    printf '%s\n' "$json"
  fi
}

_ask_debug_headers() {
  local h
  for h in "$headers[@]"; do
    [[ "$h" == -H ]] && continue
    case "$h" in
      Authorization:*)  print -r -- 'Authorization: Bearer <redacted>' ;;
      x-api-key:*)      print -r -- 'x-api-key: <redacted>' ;;
      x-goog-api-key:*) print -r -- 'x-goog-api-key: <redacted>' ;;
      *)                print -r -- "$h" ;;
    esac
  done
}

_ask_debug_context() {
  local curl_max=$_ASK_CURL_TIMEOUT_FAST
  [[ $mode == smart ]] && curl_max=$_ASK_CURL_TIMEOUT_SMART

  {
    print -- '── ask: context ──'
    printf 'cwd: %s\n' "$PWD"
    printf 'provider: %s\n' "$provider"
    printf 'model: %s\n' "$model"
    printf 'mode: %s\n' "$mode"
    printf 'url: %s\n' "$url"
    printf 'max tokens: %s\n' "$max_tok"
    printf 'curl timeout: connect=%ss total=%ss\n' "$_ASK_CURL_CONNECT_TIMEOUT" "$curl_max"
    printf 'flags: cache=%s context=%s explain=%s alts=%s retry=%s refine=%s\n' \
      "$use_cache" "$use_context" "$explain" "$alts" "$retry" "$refine"
    printf 'askrc: %s\n' "${askrc_path:-none}"
    printf 'cwd context: %s\n' "${cwd_context:-none}"
    if (( ${#file_paths} )); then
      printf 'file context: %s\n' "${(j:, :)file_paths}"
    else
      print -- 'file context: none'
    fi
    printf 'stdin bytes: %d\n' "${#stdin_data}"
    printf 'system prompt bytes: %d\n' "${#sys}"
    printf 'task bytes: %d\n' "${#task_full}"
    printf 'request body bytes: %d\n' "${#body}"
    printf 'cache key: %s\n' "$cache_key"
    printf 'cache file: %s\n' "$cache_file"
    print -- 'headers:'
    _ask_debug_headers
    print -- 'stream filter:'
    print -r -- "$stream_filter"
    print -- 'stop sequences:'
    _ask_debug_json "$stop_json"
    print -- ''
  } >&2
}

_ask_debug_request() {
  {
    print -- '── ask: request body ──'
    _ask_debug_json "$body"
    print -- ''
  } >&2
}

_ask_debug_response() {
  local raw=$1 buf=$2 net_err=$3
  local line payload

  {
    print -- '── ask: raw response ──'
    if [[ ! -s "$raw" ]]; then
      print -- '<empty>'
    else
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == data:\ * ]]; then
          payload="${line#data: }"
          if [[ "$payload" == "[DONE]" ]]; then
            print -- 'data: [DONE]'
          else
            print -- 'data:'
            _ask_debug_json "$payload"
          fi
        elif [[ -n "$line" ]]; then
          _ask_debug_json "$line"
        else
          print -- ''
        fi
      done < "$raw"
    fi
    print -- ''
    print -- '── ask: parsed text ──'
    if [[ -s "$buf" ]]; then
      sed -n '1,200p' "$buf"
    else
      print -- '<empty>'
    fi
    print -- ''
    print -- '── ask: transport stderr ──'
    if [[ -s "$net_err" ]]; then
      sed -n '1,80p' "$net_err"
    else
      print -- '<empty>'
    fi
    print -- ''
  } >&2
}

_ask_json_error() {
  jq -r '
    if .error? then
      if (.error | type) == "object" then
        [(.error.type? // empty), (.error.code? // empty), (.error.message? // empty)]
        | map(select(. != ""))
        | join(": ")
      elif (.error | type) == "string" then
        .error
      else
        empty
      end
    elif .message? then
      .message
    else
      empty
    end
  ' 2>/dev/null
}

# Escape a string for safe embedding in an XML attribute or text body.
# Pure zsh substitutions — no fork. & must go first or we double-escape
# (e.g. < → &lt; → &amp;lt;). Used on file paths in <file path="...">
# tags and on file contents so a path with a literal " or contents
# containing </file> don't break the envelope.
_ask_xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  printf '%s' "$s"
}

# ──────────────────────────────────────────────────────────────────────
# Provider abstraction. Each provider gets one associative array of
# fixed data (api-key env name, default model, URL template, stream
# filter) plus one jq body-builder function. Adding another provider:
#   1. Add a `_ASK_PROV_<NAME>` array literal below.
#   2. Write `_ask_body_<name>` that emits the request body JSON.
#   3. Add the canonical name to `_ask_validate_provider`.
#   4. Add a clause to `_ask_resolve_provider`'s autodetect chain.
# No edits to ask() are required.
#
# typeset -gA + bare reassign clears existing entries on re-source so a
# dev-time edit + source doesn't leave stale keys around.
# ──────────────────────────────────────────────────────────────────────

typeset -gA _ASK_PROV_GEMINI
_ASK_PROV_GEMINI=(
  api_key_env    GEMINI_API_KEY
  default_model  gemini-3.5-flash
  model_env      GEMINI_MODEL
  url_template   'https://generativelanguage.googleapis.com/v1beta/models/__MODEL__:streamGenerateContent?alt=sse'
  stream_filter  '.candidates[0].content.parts[]? | select(.text != null) | .text'
)

typeset -gA _ASK_PROV_OPENAI
_ASK_PROV_OPENAI=(
  api_key_env    OPENAI_API_KEY
  default_model  gpt-5.4-mini
  model_env      OPENAI_MODEL
  url_template   'https://api.openai.com/v1/responses'
  stream_filter  'select(.type == "response.output_text.delta") | .delta'
)

typeset -gA _ASK_PROV_CLAUDE
_ASK_PROV_CLAUDE=(
  api_key_env    ANTHROPIC_API_KEY
  default_model  claude-sonnet-4-6
  model_env      ANTHROPIC_MODEL
  url_template   'https://api.anthropic.com/v1/messages'
  stream_filter  'select(.type == "content_block_delta" and .delta.type == "text_delta") | .delta.text'
)

typeset -gA _ASK_PROV_OLLAMA
_ASK_PROV_OLLAMA=(
  api_key_env    ''
  default_model  ''
  model_env      OLLAMA_MODEL
  url_template   '__OLLAMA_URL__'
  stream_filter  'select(.choices != null) | .choices[0].delta.content // empty'
)

# Body builders. Args: $1=sys, $2=task, $3=model, $4=mode, $5=max_tok,
# $6=stop_json. Emit the JSON request body on stdout. Per-provider
# divergence lives only here.

_ask_body_gemini() {
  local sys=$1 task=$2 model=$3 mode=$4 max_tok=$5 stop_json=$6 lvl
  [[ $mode == smart ]] && lvl=high || lvl=low
  jq -n --arg s "$sys" --arg t "$task" --arg lvl "$lvl" \
        --argjson mt "$max_tok" --argjson stop "$stop_json" '{
    system_instruction: {parts: [{text: $s}]},
    contents: [{parts: [{text: $t}]}],
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: $mt,
      stopSequences: $stop,
      thinkingConfig: {thinkingLevel: $lvl}
    }
  }'
}

_ask_body_openai() {
  local sys=$1 task=$2 model=$3 mode=$4 max_tok=$5 effort
  [[ $mode == smart ]] && effort=high || effort=low
  jq -n --arg s "$sys" --arg t "$task" --arg m "$model" --arg e "$effort" \
        --argjson mt "$max_tok" '{
    model: $m,
    max_output_tokens: $mt,
    reasoning: {effort: $e},
    instructions: $s,
    input: $t,
    stream: true
  }'
}

# Claude smart-mode uses extended thinking (separate budget_tokens,
# no temperature or stop_sequences). Fast-mode is plain messages with
# temperature/stop. Two distinct bodies — keep them obvious.
_ask_body_claude() {
  local sys=$1 task=$2 model=$3 mode=$4 max_tok=$5 stop_json=$6
  if [[ $mode == smart ]]; then
    jq -n --arg s "$sys" --arg t "$task" --arg m "$model" \
          --argjson max "$_ASK_CLAUDE_SMART_MAX" \
          --argjson bud "$_ASK_CLAUDE_SMART_BUDGET" '{
      model: $m,
      max_tokens: $max,
      thinking: {type: "enabled", budget_tokens: $bud},
      system: $s,
      messages: [{role: "user", content: $t}],
      stream: true
    }'
  else
    jq -n --arg s "$sys" --arg t "$task" --arg m "$model" \
          --argjson mt "$max_tok" --argjson stop "$stop_json" '{
      model: $m,
      max_tokens: $mt,
      temperature: 0.2,
      stop_sequences: $stop,
      system: $s,
      messages: [{role: "user", content: $t}],
      stream: true
    }'
  fi
}

_ask_body_ollama() {
  local sys=$1 task=$2 model=$3 mode=$4 max_tok=$5 stop_json=$6
  jq -n --arg s "$sys" --arg t "$task" --arg m "$model" \
        --argjson mt "$max_tok" --argjson stop "$stop_json" '{
    model: $m,
    messages: [
      {role: "system", content: $s},
      {role: "user", content: $t}
    ],
    stream: true,
    temperature: 0.2,
    max_tokens: $mt,
    stop: $stop
  }'
}

_ask_ollama_url() {
  local base="${OLLAMA_BASE_URL:-${OLLAMA_HOST:-http://127.0.0.1:11434}}"
  [[ "$base" != http://* && "$base" != https://* ]] && base="http://$base"
  base="${base%/}"
  if [[ "$base" == */v1 ]]; then
    printf '%s/chat/completions' "$base"
  else
    printf '%s/v1/chat/completions' "$base"
  fi
}

_ask_default_ollama_model() {
  command -v ollama &>/dev/null || return 0
  ollama list 2>/dev/null | awk 'NR > 1 && $1 != "" { print $1; exit }'
}

# Canonicalise a provider name (aliases → canonical) or die on unknown.
# Modifies caller-scope $provider via dynamic scope; caller declares
# `local provider`. Centralising this means a typo (-p gemeni) dies
# here in the first ~50 lines of ask() rather than ~800 lines in.
_ask_validate_provider() {
  case "$1" in
    gemini|google)         provider=gemini ;;
    openai|chatgpt|gpt)    provider=openai ;;
    claude|anthropic)      provider=claude ;;
    ollama|local)           provider=ollama ;;
    '')   _ask_die 'no provider found. Set GEMINI_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, or use --ollama with -m MODEL.'; return 1 ;;
    *)    _ask_die "unknown provider: '$1' (use gemini, openai, claude, or ollama)"; return 1 ;;
  esac
}

# Resolve provider when nothing explicit was given: env var, then
# autodetect from configured API keys / local Ollama models in
# preference order.
# Mutates $provider via dynamic scope.
_ask_resolve_provider() {
  [[ -n "$provider" ]] && return 0
  provider="${ASK_PROVIDER:-}"
  [[ -z "$provider" && -n "$GEMINI_API_KEY"    ]] && provider=gemini
  [[ -z "$provider" && -n "$ANTHROPIC_API_KEY" ]] && provider=claude
  [[ -z "$provider" && -n "$OPENAI_API_KEY"    ]] && provider=openai
  [[ -z "$provider" && -n "$OLLAMA_MODEL"       ]] && provider=ollama
  if [[ -z "$provider" ]]; then
    local ollama_model
    ollama_model=$(_ask_default_ollama_model)
    if [[ -n "$ollama_model" ]]; then
      provider=ollama
      model="${model:-$ollama_model}"
    fi
  fi
}

# Verify the API key env var for the chosen provider is set. Uses
# the provider hash to look up the env var name, so adding a new
# provider doesn't require touching this function.
_ask_require_key() {
  local prov=$1 array_name key_var
  case "$prov" in
    gemini) array_name=_ASK_PROV_GEMINI ;;
    openai) array_name=_ASK_PROV_OPENAI ;;
    claude) array_name=_ASK_PROV_CLAUDE ;;
    ollama) return 0 ;;
    *) _ask_die "internal: _ask_require_key called with unknown provider '$prov'"; return 1 ;;
  esac
  # zsh indirect array lookup: ${(P)name[key]}
  key_var=${${(P)array_name}[api_key_env]}
  if [[ -z "${(P)key_var}" ]]; then
    _ask_die "$key_var not set"
    return 1
  fi
}

# Resolve the model name: CLI/askrc override > env override > default.
# Mutates $model via dynamic scope so caller doesn't need to capture.
_ask_resolve_model() {
  local prov=$1 array_name env_var default
  case "$prov" in
    gemini) array_name=_ASK_PROV_GEMINI ;;
    openai) array_name=_ASK_PROV_OPENAI ;;
    claude) array_name=_ASK_PROV_CLAUDE ;;
    ollama) array_name=_ASK_PROV_OLLAMA ;;
  esac
  env_var=${${(P)array_name}[model_env]}
  default=${${(P)array_name}[default_model]}
  model="${model:-${(P)env_var:-$default}}"
  if [[ "$prov" == ollama && -z "$model" ]]; then
    model=$(_ask_default_ollama_model)
  fi
  if [[ "$prov" == ollama && -z "$model" ]]; then
    _ask_die 'no Ollama model found. Pass -m MODEL or set OLLAMA_MODEL.'
    return 1
  fi
}

# Build a provider request. Sets caller-scope $url, $stream_filter,
# $body, and the $headers array via dynamic scope.
# Args: $1=provider $2=sys $3=task $4=model $5=mode $6=max_tok $7=stop_json
# Caller must have `local url body stream_filter` and
# `local -a headers=(-H 'Content-Type: application/json')` declared.
_ask_provider_request() {
  local prov=$1 sys=$2 task=$3 mdl=$4 mode=$5 max_tok=$6 stop_json=$7
  local array_name url_tmpl key_env key_val

  case "$prov" in
    gemini) array_name=_ASK_PROV_GEMINI ;;
    openai) array_name=_ASK_PROV_OPENAI ;;
    claude) array_name=_ASK_PROV_CLAUDE ;;
    ollama) array_name=_ASK_PROV_OLLAMA ;;
    *) _ask_die "internal: _ask_provider_request called with unknown provider '$prov'"; return 1 ;;
  esac

  url_tmpl=${${(P)array_name}[url_template]}
  stream_filter=${${(P)array_name}[stream_filter]}
  url=${url_tmpl//__MODEL__/$mdl}
  url=${url//__OLLAMA_URL__/$(_ask_ollama_url)}

  key_env=${${(P)array_name}[api_key_env]}
  [[ -n "$key_env" ]] && key_val=${(P)key_env} || key_val=""

  # API keys go in headers, never in URL — keeps them out of $url
  # which could leak via xtrace, debug dumps, or screenshots.
  case "$prov" in
    gemini)
      headers+=(-H "x-goog-api-key: $key_val")
      body=$(_ask_body_gemini "$sys" "$task" "$mdl" "$mode" "$max_tok" "$stop_json")
      ;;
    openai)
      headers+=(-H "Authorization: Bearer $key_val")
      body=$(_ask_body_openai "$sys" "$task" "$mdl" "$mode" "$max_tok" "$stop_json")
      ;;
    claude)
      headers+=(
        -H "x-api-key: $key_val"
        -H 'anthropic-version: 2023-06-01'
      )
      body=$(_ask_body_claude "$sys" "$task" "$mdl" "$mode" "$max_tok" "$stop_json")
      ;;
    ollama)
      body=$(_ask_body_ollama "$sys" "$task" "$mdl" "$mode" "$max_tok" "$stop_json")
      ;;
  esac
}

# Parse flags. Mutates caller-scope vars (provider, model, mode,
# use_cache, use_context, debug, explain, alts) via dynamic scope.
# Populates caller-scope _ask_rest array with remaining positional args.
# Returns: 0 on success, 1 on validation error, 2 on clean early exit
# (help shown or cache cleared — caller should return 0).
_ask_parse_flags() {
  local cache_dir=$1; shift
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)              _ask_help; return 2 ;;
      -g|--gemini|--google)   provider=gemini; shift ;;
      -o|--openai|--gpt|-gpt) provider=openai; shift ;;
      -c|--claude)            provider=claude; shift ;;
      -l|--local|--ollama)    provider=ollama; shift ;;
      -p|--provider)          provider="$2"; shift 2 ;;
      -m|--model)             model="$2";    shift 2 ;;
      -s|--smart)             mode=smart; shift ;;
      -f|--fast)              mode=fast;  shift ;;
      -d|--debug)             debug=1; shift ;;
      -e|--explain)           explain=1; shift ;;
      -a|--alts)
        # Reject non-numeric or out-of-range up front so a typo
        # ("? --alts find rust files") doesn't silently swallow the
        # task and fire a useless burst of duplicate requests.
        if [[ "$2" != <-> ]] || (( $2 < _ASK_ALTS_MIN || $2 > _ASK_ALTS_MAX )); then
          _ask_die "--alts needs an integer ${_ASK_ALTS_MIN}-${_ASK_ALTS_MAX} (got: $2)"
          return 1
        fi
        alts="$2"; shift 2 ;;
      --no-cache)             use_cache=0; shift ;;
      --clear-cache)          rm -rf -- "$cache_dir"; echo 'ask: cache cleared'; return 2 ;;
      --no-context)           use_context=0; shift ;;
      --)                     shift; break ;;
      -*)                     _ask_die "unknown flag: $1 (try -h)"; return 1 ;;
      *)                      break ;;
    esac
  done
  _ask_rest=("$@")
}

# Read each file in the named array as labelled context. Honors a
# combined 32K budget across all files. XML-escapes path and content
# so a filename with " or a file containing </file> can't break the
# envelope. Returns the assembled <file>…</file> blocks on stdout.
_ask_read_files() {
  local arrname=$1
  local fp content take actual size_str note escaped_path escaped_content
  local file_budget=$_ASK_FILE_CAP
  local out=""
  # ${(P)arrname} is zsh's indirect parameter expansion — dereferences
  # the array whose name we got as a string.
  local -a files=("${(@P)arrname}")

  for fp in "${files[@]}"; do
    if (( file_budget <= 0 )); then
      printf '\033[2m▸ skipping %s (32K context budget exhausted)\033[0m\n' "$fp" >&2
      continue
    fi
    content=$(head -c "$file_budget" -- "$fp" 2>/dev/null) || continue
    take=${#content}
    (( take == 0 )) && continue
    escaped_path=$(_ask_xml_escape "$fp")
    escaped_content=$(_ask_xml_escape "$content")
    out+=$'<file path="'"$escaped_path"$'">\n'"$escaped_content"$'\n</file>\n'
    # GNU stat uses -c, BSD/macOS uses -f; if neither flag is supported
    # we just skip the size display rather than printing an error.
    actual=$(stat -c%s -- "$fp" 2>/dev/null || stat -f%z -- "$fp" 2>/dev/null)
    if (( take >= 1024 )); then
      size_str=$(printf '%.1fK' "$(( take / 1024.0 ))")
    else
      size_str="${take}B"
    fi
    note=""
    # Truncated only if actual file is bigger than the budget we had
    # going in. Comparing take<actual is wrong because command sub
    # strips trailing newlines (so an 11-byte read of a 12-byte file
    # would look truncated).
    [[ -n "$actual" ]] && (( actual > file_budget )) && note=' (truncated, 32K cap)'
    printf '\033[2m▸ reading %s · %s%s\033[0m\n' "$fp" "$size_str" "$note" >&2
    (( file_budget -= take ))
  done
  printf '%s' "$out"
}

# Build the user-facing task wrapper. Combines piped stdin and file
# context blocks with the user's typed words into a single labelled
# envelope. Mutates caller-scope $task and $original_task via dynamic
# scope.
# Args: $1=user_task $2=stdin_data $3=file_data $4=files_array_name
_ask_build_context() {
  local user_task=$1 stdin_data=$2 file_data=$3 arrname=$4
  local escaped_stdin ctx="" hint stub=""
  local -a files=("${(@P)arrname}")

  [[ -n "$stdin_data" ]] && {
    escaped_stdin=$(_ask_xml_escape "$stdin_data")
    ctx+=$'<stdin context>\n'"$escaped_stdin"$'\n</stdin context>\n'
  }
  [[ -n "$file_data" ]] && ctx+=$'<files context>\n'"$file_data"$'</files context>\n'

  if [[ -n "$ctx" ]]; then
    if [[ -n "$stdin_data" && -n "$file_data" ]]; then
      hint='(figure out what to do with the stdin and files)'
    elif [[ -n "$stdin_data" ]]; then
      hint='(figure out what to do with the stdin context)'
    else
      hint='(explain or operate on these files)'
    fi
    task=$ctx$'\nuser intent: '"${user_task:-$hint}"
  fi
  # original_task feeds the retry indicator and .last_task save.
  # Prefer typed text; fall back to a stub from piped/pointed inputs
  # so the indicator isn't blank.
  [[ -n "$stdin_data" ]] && stub+="stdin "
  (( ${#files} )) && stub+="${files[1]} "
  original_task="${user_task:-${stub% }}"
}

# Detect bare `?` retry condition: no args, no stdin, no files, and a
# recent .last_attempts.jsonl exists. If so, rebuild task as the
# original intent + up to 3 prior failed attempts and set
# retry=1, use_cache=0. Returns 0 (retry loaded) or 1 (no retry).
# Mutates caller-scope $task, $original_task, $use_cache, $retry.
_ask_load_retry() {
  local cache_dir=$1 user_task=$2 stdin_data=$3 file_data=$4
  local attempts_file=$cache_dir/.last_attempts.jsonl
  local last_task attempts_text indicator

  [[ -n "$user_task" || -n "$stdin_data" || -n "$file_data" ]] && return 1
  [[ -f "$attempts_file" ]] || return 1
  [[ -n "$(find "$attempts_file" -mmin -$_ASK_RETRY_WINDOW_MIN 2>/dev/null)" ]] || return 1

  last_task=$(< "$cache_dir/.last_task" 2>/dev/null)
  # jq -s slurps the JSONL into an array; we then format each attempt
  # with a 1-based index so the model can refer to them naturally
  # ("attempt 2 fixed X but reintroduced Y").
  attempts_text=$(jq -r -s 'to_entries
    | map("attempt \(.key+1):\n  command: \(.value.cmd)\n  stderr: \(.value.stderr)")
    | join("\n\n")' < "$attempts_file" 2>/dev/null)
  task=$'original intent:\n'"${last_task:-(unknown)}"$'\n\nfailed prior attempts (oldest first):\n'"$attempts_text"$'\n\nproduce a corrected single command.'
  original_task="$last_task"
  use_cache=0
  retry=1

  # Show the user *what* we're retrying so they can confirm the right
  # context got carried over (and Ctrl+C if it didn't).
  indicator="${last_task:-failed command}"
  (( ${#indicator} > _ASK_INDICATOR_MAX )) \
    && indicator="${indicator:0:$(( _ASK_INDICATOR_MAX - 3 ))}..."
  printf '\033[2mretrying: %s\033[0m\n' "$indicator"
}

# Compute token budget. Smart mode needs much more headroom because
# OpenAI's max_output_tokens is shared between reasoning and visible
# output; Gemini same. Explain mode adds room for the why-comment.
# Alts mode multiplies budget by candidate count + per-alt overhead.
# Echoes the integer on stdout.
_ask_max_tokens() {
  local mode=$1 explain=$2 alts=$3 max_tok
  [[ $mode == smart ]] && max_tok=$_ASK_TOKENS_SMART || max_tok=$_ASK_TOKENS_FAST
  (( explain )) && max_tok=$(( max_tok + _ASK_TOKENS_EXPLAIN_BONUS ))
  # NB: a previous version used `(( mode != smart ))` which compares
  # strings as numbers (both → 0), so the bonus was silently always
  # added. `[[ ]]` for string compare here.
  if (( alts > 1 )) && [[ $mode != smart ]]; then
    max_tok=$(( max_tok + alts * _ASK_TOKENS_PER_ALT ))
  fi
  printf '%s' "$max_tok"
}

# Build the per-request system-prompt addendum (retry/refine/explain/
# alts directives + .askrc free-form text). Echoes the accumulated
# directives on stdout. Caller appends to $sys after _ask_sys.
# Args: $1=askrc_prompt $2=retry $3=refine $4=explain $5=alts
_ask_extra_directives() {
  local askrc=$1 retry=$2 refine=$3 explain=$4 alts=$5
  local out=""

  [[ -n "$askrc" ]] && out+=$'\n\nPROJECT DIRECTIVES (from .askrc)\n'"$askrc"

  if (( retry )); then
    out+=$'\n\nRETRY MODE\nThe user message contains the original intent and one or more failed prior attempts (each with the command and its stderr). Diagnose from the stderrs, learn what already failed, and stay anchored to the original intent — do not drift toward a different goal. Output a single corrected command per the OUTPUT CONTRACT — no apology, no explanation, no acknowledgment of the prior failures.'
  elif (( refine )); then
    out+=$'\n\nREFINE MODE\nThe user message contains the original intent, a previous candidate command, and a refinement directive from the user. Apply the refinement while preserving the original intent. Output a single corrected command per the OUTPUT CONTRACT — no apology, no explanation.'
  fi

  if (( explain )); then
    out+=$'\n\nEXPLAIN MODE OVERRIDE
This overrides rule 4 ("zero # comments") for this request only.

After the command, append exactly one space, then "# why: <clause>". One line total.

Rules for the why clause:
- One short sentence, up to ~20 words. Dense, no filler.
- Decode packed/short flags: "-tulpn" → "-t tcp, -u udp, -l listen, -p process, -n numeric".
- Call out magic values: "-mtime takes days; negative means newer-than".
- Explain why this tool over the obvious alternative when relevant.
- No restating what the command does ("this finds rust files" wastes the line). Skip the verb, go to the gotcha.
- If the command is genuinely obvious, the why points out the non-obvious knob anyway.
- Pack two short pieces with "; " if both matter (e.g. flag expansion AND a sudo reason).

Examples:
INPUT: find rust files modified in the last week
OUTPUT: find . -type f -name \'*.rs\' -mtime -7 # why: -mtime takes days; negative means newer-than

INPUT: 10 largest files under this directory
OUTPUT: du -ah . 2>/dev/null | sort -rh | head -10 # why: -h human sizes; -rh sorts numerically by suffix (K/M/G)

INPUT: show all open ports with the owning process
OUTPUT: sudo ss -tulpn # why: -t tcp, -u udp, -l listen-only, -p process, -n numeric; sudo so -p sees other-user owners

INPUT: kill whatever is listening on port 3000
OUTPUT: kill -9 "$(lsof -t -i:3000)" # why: lsof -t prints only the PID, suitable for piping to kill

INPUT: copy current branch name to clipboard
OUTPUT: git rev-parse --abbrev-ref HEAD | tr -d \'\\n\' | wl-copy # why: tr -d strips the trailing newline so paste is clean'
  fi

  # Alts mode adds N-candidate directives. First-iter only — refine/
  # retry paths keep their single-answer contract since the user
  # already picked one.
  if (( alts > 1 && retry == 0 && refine == 0 )); then
    out+=$'\n\nALTS MODE OVERRIDE
This OVERRIDES output contract rules 1 ("exactly one command or pipeline") and 8 ("single line preferred") for this request only.

Produce exactly '"$alts"$' distinct alternative commands solving the user request, separated by sentinel lines.

Format — character-exact:
=== alt 1 ===
<first command>
=== alt 2 ===
<second command>
... continuing through ===
=== alt '"$alts"$' ===
<last command>

Rules:
- Exactly '"$alts"$' alternatives. Not '$(( alts - 1 ))$', not '$(( alts + 1 ))$'.
- Each alternative must be GENUINELY DIFFERENT in approach — different tool, different pipeline, different flag set. Trivial rewordings (e.g. "-name X" vs "--name=X", or reordered flags) do NOT count as alternatives and are wasted slots.
- Each alternative individually follows ALL other OUTPUT CONTRACT rules: no markdown, no prose, no placeholders, no leading prompt chars, no echo wrappers, no # comments (unless EXPLAIN MODE is also active).
- A single command per alternative; may span multiple lines for legitimate for/while/case loops, but stays one logical command.
- ZERO commentary or prose anywhere — not before the first sentinel, not between alternatives, not after the last.
- The sentinel line is literal: three equals signs, one space, the word "alt", one space, the 1-based index number, one space, three equals signs. No additional whitespace, no markdown, nothing on the line but the sentinel.
- Order the alternatives from most likely-to-be-wanted to most specialized — the user sees them in this order in the picker.'
  fi

  printf '%s' "$out"
}

# Start the background curl→tee→sed→jq pipeline that streams text
# deltas from the chosen provider into $buf. Sets caller-scope
# $pipe_pid (dynamic scope) to the disowned pid so the spinner can
# `kill -0` it. Trap on INT must already be installed by the caller.
# Args: $1=url $2=headers_array_name $3=body $4=stream_filter
#       $5=mode $6=buf_path $7=raw_path $8=transport_stderr_path
_ask_stream() {
  local url=$1 headers_name=$2 body=$3 filter=$4 mode=$5 buf=$6 raw=$7 net_err=$8
  local -a hdrs=("${(@P)headers_name}")
  local curl_max=$_ASK_CURL_TIMEOUT_FAST
  [[ $mode == smart ]] && curl_max=$_ASK_CURL_TIMEOUT_SMART
  # `&!` = background + disown immediately. With MONITOR on (needed
  # for reads to work post-pipeline), a plain `&` would print the
  # job-table announce/done lines into the user's terminal. Disowning
  # drops it from the job table so those notifications never fire;
  # we still get $! and can poll with `kill -0` for completion.
  #
  # Block-level redirections sever the bg subshell from the user's
  # terminal: `</dev/null` so curl can never read from terminal stdin,
  # `9<&-` so the inherited /dev/tty fd (opened for confirm prompts)
  # is closed in the bg children, `2>/dev/null` so tee/grep/sed errors
  # don't leak. Without these, the bg job's inherited fds (especially
  # fd 9 → /dev/tty) survive past ask()'s EXIT-trap close and confuse
  # tty-probing programs run next (e.g. `codex login`, other TUIs).
  {
    curl -sS -N --fail-with-body \
         --connect-timeout "$_ASK_CURL_CONNECT_TIMEOUT" \
         --max-time "$curl_max" \
         "$url" "${hdrs[@]}" -d "$body" 2>"$net_err" \
    | tee -- "$raw" \
    | grep --line-buffered '^data: ' \
    | sed -u 's/^data: //' \
    | jq --unbuffered -j "$filter" 2>/dev/null \
    > "$buf"
  } </dev/null 9<&- 2>/dev/null &!
  pipe_pid=$!
}

# Spin while the background pipeline runs. Two variants: alts mode
# waits for the full response (we need all sentinels before parsing)
# and counts them; single-answer mode spins only until first delta
# then hands off to the typewriter. Reads $cancelled from dynamic
# scope to bail on Ctrl+C.
# Args: $1=pipe_pid $2=buf_path $3=alts $4=retry $5=refine
_ask_spinner_wait() {
  local pid=$1 buf=$2 alts=$3 retry=$4 refine=$5
  local fi=0 seen=0
  local frames=$_ASK_SPINNER_FRAMES

  if (( alts > 1 && retry == 0 && refine == 0 )); then
    while kill -0 "$pid" 2>/dev/null; do
      (( cancelled )) && break
      seen=$(grep -c '^[[:space:]]*===[[:space:]]\+alt[[:space:]]\+[0-9]\+' "$buf" 2>/dev/null)
      seen=${seen:-0}
      printf '\r\033[1;36m%s\033[0m generating alternatives… (%d/%d)' \
        "${frames:$fi:1}" "$seen" "$alts"
      (( fi = (fi + 1) % ${#frames} ))
      sleep "$_ASK_SPINNER_SLEEP"
    done
    printf '\r\033[K'
  else
    while kill -0 "$pid" 2>/dev/null && [[ ! -s "$buf" ]]; do
      printf '\r\033[1;36m%s\033[0m thinking…' "${frames:$fi:1}"
      (( fi = (fi + 1) % ${#frames} ))
      sleep "$_ASK_SPINNER_SLEEP"
    done
    printf '\r\033[K'
  fi
}

# Classify a streaming failure. Looks at the raw response file for a
# provider error JSON; if not found, falls back to a generic message.
# Echoes a one-line typed-error string on stdout — caller passes it
# to _ask_api_die / _ask_parse_die for the actual exit.
_ask_check_curl_exit() {
  local raw=$1 net_err=$2
  local err line payload
  err=$(_ask_json_error < "$raw")
  if [[ -n "$err" ]]; then
    printf 'api\t%s' "$err"
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == data:\ * ]] || continue
    payload="${line#data: }"
    [[ "$payload" == "[DONE]" ]] && continue
    err=$(printf '%s' "$payload" | _ask_json_error)
    if [[ -n "$err" ]]; then
      printf 'api\t%s' "$err"
      return 0
    fi
  done < "$raw"
  if [[ -s "$net_err" ]]; then
    err=$(sed -n '1,4p' "$net_err")
    err="${err//$'\n'/; }"
    printf 'network\t%s' "${err:-curl failed}"
    return 0
  fi
  if [[ -s "$raw" ]]; then
    printf 'parse\tno command returned (raw response captured; rerun with --debug)'
  else
    printf 'parse\tno command returned (empty response)'
  fi
}

# Clean a single-command response: strip markdown fences, leading
# prompt chars ($/%), and surrounding whitespace. Echoes the cleaned
# command on stdout.
_ask_clean_command() {
  local s
  s=$(printf '%s' "$1" \
    | sed -E '1{s/^[[:space:]]*(```|~~~)[[:alnum:]]*[[:space:]]*$//; s/^[[:space:]]*(```|~~~)[[:alnum:]]*[[:space:]]*//}; ${s/[[:space:]]*(```|~~~)[[:space:]]*$//}')
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  [[ "$s" == '$ '* || "$s" == '% '* ]] && s="${s:2}"
  printf '%s' "$s"
}

# Parse a sentinel-delimited alts response into candidates, dedupe
# preserving order, and pick one via fzf (or numbered menu fallback).
# Echoes the chosen command on stdout (empty if user aborted).
# Args: $1=cmd_buf $2=alts_requested
_ask_parse_alts() {
  local cmd_buf=$1 alts=$2
  local parsed_nul c pre_dedupe dedupe_loss shortfall pick n
  local -a candidates cleaned why

  # awk emits each candidate block followed by a NUL byte; zsh
  # ${(0)var} splits on NULs into an array. Robust against multi-
  # line candidates (for/while loops, heredocs).
  parsed_nul=$(printf '%s' "$cmd_buf" | awk '
    /^[[:space:]]*===[[:space:]]+alt[[:space:]]+[0-9]+[[:space:]]+===[[:space:]]*$/ {
      if (have && buf != "") printf "%s%c", buf, 0
      buf=""; have=1; next
    }
    have { buf = (buf == "" ? $0 : buf "\n" $0) }
    END { if (have && buf != "") printf "%s%c", buf, 0 }
  ')
  candidates=("${(0)parsed_nul}")

  # Per-candidate cleanup mirrors the single-answer path.
  for c in "${candidates[@]}"; do
    c=$(_ask_clean_command "$c")
    [[ -n "$c" ]] && cleaned+=("$c")
  done

  # Dedupe while preserving order. Track shortfall + dedupe loss
  # separately so the status message can say *why* we got fewer
  # candidates than requested.
  pre_dedupe=${#cleaned}
  cleaned=("${(@u)cleaned}")
  dedupe_loss=$(( pre_dedupe - ${#cleaned} ))
  shortfall=$(( alts - pre_dedupe ))

  if (( ${#cleaned} == 0 )); then
    _ask_parse_die 'model did not produce the expected sentinel format (try --debug)'
    return 1
  fi

  if (( shortfall > 0 || dedupe_loss > 0 )); then
    (( shortfall > 0   )) && why+=("$shortfall missing")
    (( dedupe_loss > 0 )) && why+=("$dedupe_loss duplicate")
    printf '\033[2m▸ %d/%d candidates (%s)\033[0m\n' \
      "${#cleaned}" "$alts" "${(j:, :)why}" >&2
  fi

  # Picker. fzf --read0 handles multi-line candidates as single
  # records. Numbered fallback reads from fd 9 to avoid stdin
  # collision with the streaming pipeline.
  if command -v fzf &>/dev/null; then
    pick=$(printf '%s\0' "${cleaned[@]}" \
      | fzf --read0 --prompt='alt > ' --height=60% --reverse --ansi \
            --header='enter = pick · esc = abort' \
            --color='header:dim')
    pick="${pick%$'\n'}"
    printf '%s' "$pick"
  else
    printf '\033[2m── alternatives ──\033[0m\n' >&2
    n=1
    for c in "${cleaned[@]}"; do
      printf '\033[1;36m%d)\033[0m \033[1;33m%s\033[0m\n' "$n" "$c" >&2
      (( n++ ))
    done
    printf 'pick [1-%d]: ' "${#cleaned}" >&2
    read -r -u 9 pick
    if [[ "$pick" == <-> ]] && (( pick >= 1 && pick <= ${#cleaned} )); then
      printf '%s' "${cleaned[$pick]}"
    fi
  fi
}

# Atomically save a single-answer command to cache. Creates the cache
# dir first; uses _ask_save (mktemp+rename) for atomicity.
_ask_save_to_cache() {
  local cache_dir=$1 cache_file=$2 cmd=$3
  [[ -n "$cmd" ]] || return 0
  mkdir -p -- "$cache_dir" 2>/dev/null || return 1
  printf '%s' "$cmd" | _ask_save "$cache_file"
}

# Confirm prompt. Reads from fd 9 (controlling tty — immune to stdin
# hijacking). Sets caller-scope $next_action to one of {done, abort,
# generate}; may mutate $cmd (E: edit), $task/$use_cache/$refine/
# $retry (R: refine). Reads $cache_file, $cache_dir, $use_cache,
# $original_task from caller scope.
_ask_confirm() {
  local confirm refinement prev_cmd
  while true; do
    printf '\033[1;37mRun?\033[0m  [\033[32mY\033[0m]\033[2mes\033[0m  [\033[1;31mN\033[0m]\033[2mo\033[0m  [\033[34mE\033[0m]\033[2mdit\033[0m  [\033[33mR\033[0m]\033[2mefine\033[0m  [\033[2m?\033[0m] '
    read -r -u 9 confirm
    case "$confirm" in
      [Yy]*) next_action=done; return ;;
      [Ee]*)
        # Strip any trailing " # ..." comment before editing — explain
        # mode's why-note (and any stray model comment) just clutters
        # the edit. Leading space anchors so "#" inside a token (e.g.
        # awk "#") isn't matched; [#] keeps the # literal under
        # EXTENDED_GLOB (where bare # is a postfix op).
        cmd="${cmd% [#]*}"
        cmd="${cmd%"${cmd##*[![:space:]]}"}"
        # vared drops into zsh's line editor on $cmd for an in-place
        # tweak (path, flag, etc.) before running.
        vared cmd
        # Persist the edit to cache so the next identical query returns
        # the user's fix, not the AI's original. Trade-off: a one-off
        # tweak (e.g. a specific path) gets baked in; users can
        # `--no-cache` or `--clear-cache` to redo.
        (( use_cache )) && _ask_save_to_cache "$cache_dir" "$cache_file" "$cmd"
        next_action=done; return ;;
      [Rr]*)
        # Refine: re-prompt the model with the original intent + the
        # current candidate + the user's directive, then loop back to
        # the build/cache/stream stage with the new task.
        printf '\033[2mrefine: \033[0m'
        read -r -u 9 refinement
        if [[ -z "$refinement" ]]; then
          _ask_warn 'empty refinement, cancelling'
          next_action=abort; return
        fi
        # Strip the explain-mode why-comment from the previous cmd so
        # the model gets only the executable part as context.
        prev_cmd="${cmd% [#]*}"
        prev_cmd="${prev_cmd%"${prev_cmd##*[![:space:]]}"}"
        task=$'original intent:\n'"${original_task:-(unknown)}"$'\n\nprevious candidate:\n'"$prev_cmd"$'\n\nrefinement:\n'"$refinement"$'\n\nproduce a corrected single command.'
        use_cache=0
        refine=1
        retry=0
        next_action=generate; return ;;
      '?'|h|H|help)
        # Inline cheat-sheet, then reprompt. Quoted '?' so the case
        # pattern matches a literal `?` rather than any single char.
        printf '\033[2m  y\033[0m  run the command\n'
        printf '\033[2m  n\033[0m  decline (default — plain Enter also works)\n'
        printf '\033[2m  e\033[0m  edit the command before running\n'
        printf '\033[2m  r\033[0m  refine: rewrite with a follow-up directive\n'
        continue ;;
      *) next_action=abort; return ;;
    esac
  done
}

# Record an exec attempt. On failure: append a new JSONL entry to
# .last_attempts.jsonl, keeping only the last _ASK_ATTEMPTS_KEEP
# entries (so retries see a bounded history). On success: clean up
# the retry-state files. Stderr truncated to last 4KB so long compiler
# dumps don't blow the next prompt budget.
# Args: $1=cache_dir $2=cmd $3=err_file $4=rc $5=original_task
_ask_record_attempt() {
  local cache_dir=$1 cmd=$2 err_file=$3 rc=$4 original_task=$5
  local attempts_file=$cache_dir/.last_attempts.jsonl
  local last_task_file=$cache_dir/.last_task
  local entry
  local keep_lines=$(( _ASK_ATTEMPTS_KEEP - 1 ))

  mkdir -p -- "$cache_dir" 2>/dev/null

  if (( rc != 0 )) && [[ -d "$cache_dir" ]]; then
    entry=$(jq -nc --arg cmd "$cmd" \
      --arg err "$(tail -c $_ASK_STDERR_CAP -- "$err_file" 2>/dev/null)" \
      '{cmd:$cmd, stderr:$err}')
    {
      tail -n "$keep_lines" "$attempts_file" 2>/dev/null
      printf '%s\n' "$entry"
    } | _ask_save "$attempts_file"
    printf '%s' "$original_task" | _ask_save "$last_task_file"
  else
    rm -f -- "$attempts_file" "$last_task_file" 2>/dev/null
    # Tidy up the legacy single-attempt files from the older format
    # if a user is upgrading. Harmless if absent.
    rm -f -- "$cache_dir/.last_cmd" "$cache_dir/.last_stderr" 2>/dev/null
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Main entry point. ~180-line glue function over the helpers above.
# Order: setopt → constants/locals → parse flags → context → resolve →
# validate → loop (build → cache → stream → confirm) → eval → record.
# ──────────────────────────────────────────────────────────────────────
ask() {
  # NO_MULTIOS: with multios on (zsh default), `1>&4 2>&3` style redirs
  # spawn helper procs that hijack pipestatus[1] and tee stdout into the
  # stderr-capture pipe. Disable it locally so the eval-wrapper below
  # gets the eval'd command's real exit code and a clean stderr capture.
  # PIPE_FAIL: without it, a pipeline like `cmd-that-fails | head` exits
  # 0 because head succeeds, hiding the upstream failure from the retry
  # detector. Trade-off: SIGPIPE from a downstream `head` will now mark
  # the upstream as failed too — a tolerable false-positive vs. the
  # silent-failure alternative.
  # NO_XTRACE / NO_VERBOSE: hard-stop traces inside this function — the
  # request body and provider URLs can contain API keys, and we never
  # want them echoed to the terminal even if the user has xtrace on.
  # TYPESET_SILENT: critical. Without it, `local foo bar` (no values)
  # on already-declared variables dumps `foo=value\nbar=value` to the
  # terminal. Our refine loop redeclares `local sys body url ...` each
  # iteration, which on iter 2+ would otherwise leak the request body
  # *and the API key* (when it was in $url) to stdout.
  setopt LOCAL_OPTIONS LOCAL_TRAPS NO_NOTIFY NO_MULTIOS PIPE_FAIL NO_XTRACE NO_VERBOSE TYPESET_SILENT

  # Suppress zsh's default SIGCHLD notification flush. Without this,
  # when our internal `&!` curl finishes, its SIGCHLD wakes zsh's job
  # handler which prints any pending "[N] done …" notifications from
  # the *outer* pipeline (e.g. `eza` in `ls | ?`) right between our
  # streamed command and the Run? prompt. An empty TRAPCHLD overrides
  # the default — kernel still reaps zombies, our `kill -0` polling on
  # the disowned curl still works, and outer-pipeline notifications
  # stay deferred to the user's next interactive prompt instead.
  # Scoped via LOCAL_TRAPS so it reverts on function exit.
  TRAPCHLD() { :; }

  # ── State ────────────────────────────────────────────
  # `mode` starts empty so we can layer flag > .askrc > env > "fast"
  # in that order downstream. If we pre-defaulted to $ASK_MODE here,
  # .askrc couldn't tell whether the user passed --fast/--smart or
  # just inherited the env default, so the precedence would invert.
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ask"
  local provider="" model="" mode="" use_cache=1 use_context=1
  local debug=0 explain=0 alts=1 askrc_prompt=""
  local -a _ask_rest

  # ── Parse flags ──────────────────────────────────────
  _ask_parse_flags "$cache_dir" "$@"
  local parse_rc=$?
  (( parse_rc == 2 )) && return 0   # -h or --clear-cache
  (( parse_rc != 0 )) && return $parse_rc

  # ── Setup interactive fd + cleanup trap ──────────────
  # Dedicated fd for interactive prompts. Bound to the controlling tty
  # ($TTY = /dev/pts/N from zsh; /dev/tty fallback) so the confirm and
  # refine reads below are immune to stdin getting consumed by a pipe,
  # closed by the streaming pipeline, or otherwise hijacked. Closed at
  # function exit via the LOCAL_TRAPS-scoped EXIT trap. If neither tty
  # is openable (CI, no controlling terminal), fd 9 stays unbound and
  # the reads hit EOF → silent decline, which is the safe fallback.
  #
  # `exec` with no command and redirections modifies the SHELL'S fd
  # table permanently. So `exec 9<file 2>/dev/null` would close fd 9
  # AND redirect this shell's stderr to /dev/null FOREVER — breaking
  # subsequent programs (codex login, etc.) whose stderr silently
  # disappears. Wrap in `{ … } 2>/dev/null` so the stderr redirect is
  # group-scoped and reverts on group exit; the exec inside still
  # modifies the shell's fd 9 as intended.
  { exec 9<"${TTY:-/dev/tty}"; } 2>/dev/null
  # Single EXIT trap covers fd 9 and any temp files created later.
  # The variables ($raw, $buf, $err_file) are function-locals declared
  # downstream; when the trap fires, unset ones expand empty and `rm
  # -f --` ignores them. Catches both clean exits and aborts (Ctrl+C
  # mid-eval, early `return`s) without per-path duplicated cleanup.
  # Same `{ exec …; } 2>/dev/null` trick here — see note above.
  local raw="" buf="" net_err="" err_file=""
  trap 'rm -f -- "$raw" "$buf" "$net_err" "$err_file" 2>/dev/null; { exec 9<&-; } 2>/dev/null' EXIT

  # ── Split positional args: file refs vs task words ───
  # A `./path` arg is only treated as a file ref when the path actually
  # exists, is readable, and isn't a directory — otherwise it's just a
  # literal arg.
  local -a task_words file_paths
  local arg
  for arg in "${_ask_rest[@]}"; do
    if [[ "$arg" == ./?* && -r "$arg" && ! -d "$arg" ]]; then
      file_paths+=("$arg")
    else
      task_words+=("$arg")
    fi
  done
  local user_task="${task_words[*]}"

  # ── Read piped stdin as context ──────────────────────
  # `[[ -t 0 ]]` is true when stdin is a terminal — i.e. nothing piped.
  # Capped at 32KB so `cat /var/log/syslog | ?` doesn't ship megabytes
  # to the API. Prefer head over tail because the start of a log/diff
  # is usually more diagnostic than the tail.
  local stdin_data=""
  [[ ! -t 0 ]] && stdin_data=$(head -c "$_ASK_STDIN_CAP")

  # ── Read file context ────────────────────────────────
  local file_data=""
  (( ${#file_paths} )) && file_data=$(_ask_read_files file_paths)

  # ── Retry-detect / build context ─────────────────────
  local task="" original_task="" retry=0 refine=0
  if ! _ask_load_retry "$cache_dir" "$user_task" "$stdin_data" "$file_data"; then
    task="$user_task"
    _ask_build_context "$user_task" "$stdin_data" "$file_data" file_paths
    # If still empty and no context, the user typed `?` alone with
    # nothing to retry — show help and bail.
    if [[ -z "$task" && -z "$stdin_data" && -z "$file_data" ]]; then
      _ask_help >&2
      return 1
    fi
  fi

  # ── Load .askrc (CLI > .askrc > env > built-in default) ──
  local askrc_path
  if askrc_path=$(_ask_find_askrc); then
    _ask_load_askrc "$askrc_path"
  fi

  # ── Resolve and validate provider, model, mode ───────
  _ask_resolve_provider
  _ask_validate_provider "$provider" || return 1
  _ask_require_key "$provider"       || return 1
  _ask_resolve_model "$provider"     || return 1
  [[ -z "$mode" ]] && mode="${ASK_MODE:-fast}"

  # ── Detect cwd context once (doesn't change mid-call) ──
  local cwd_context=""
  (( use_context )) && cwd_context=$(_ask_context)

  # ── Main loop ────────────────────────────────────────
  # `next_action` drives iteration. Refine sets it back to "generate"
  # with a rebuilt $task; Y/E set it to "done"; N sets it to "abort".
  # No `break N` / `continue N` arithmetic — one level of while.
  local next_action="generate" cmd=""
  while [[ "$next_action" == "generate" ]]; do
    next_action=""

    # Wrap task in the cwd-context envelope for this iteration. Done
    # every loop turn (not baked into $task once) because refine
    # rebuilds $task from $original_task, which would otherwise drop
    # the context. $task_full flows into the request body and cache
    # key; $task itself stays clean for rebuilds.
    local task_full="$task"
    [[ -n "$cwd_context" ]] && task_full=$'<cwd>'"$cwd_context"$'</cwd>\n\n'"$task"

    # Build per-iteration sys prompt: static base + askrc + retry/
    # refine/explain/alts directives.
    local sys body url stream_filter max_tok
    sys=$(_ask_sys)
    sys+="$(_ask_extra_directives "$askrc_prompt" "$retry" "$refine" "$explain" "$alts")"
    max_tok=$(_ask_max_tokens "$mode" "$explain" "$alts")

    # Stop-sequences empty in alts mode (the model needs blank lines
    # between sentinels). Single-answer keeps "\n\n" so the model
    # can't drift into prose after the command.
    local stop_json='["\n\n"]'
    (( alts > 1 )) && stop_json='[]'

    local -a headers=(-H 'Content-Type: application/json')
    _ask_provider_request "$provider" "$sys" "$task_full" "$model" "$mode" "$max_tok" "$stop_json" \
      || return 1

    # ── Cache lookup ────────────────────────────────────
    # Trim leading/trailing whitespace from the task so trivial
    # spacing differences don't produce different cache keys.
    local task_key=${task_full#"${task_full%%[![:space:]]*}"}
    task_key=${task_key%"${task_key##*[![:space:]]}"}
    local cache_key cache_file cached=0
    cache_key=$(printf '%s\n%s\n%s\n%s\n%s' \
      "$provider" "$model" "$mode" "$sys" "$task_key" \
      | sha256sum | cut -d' ' -f1)
    cache_file="$cache_dir/$cache_key"

    # Alts mode forces a fresh round-trip. Caching a picked alt would
    # make the next ` --alts N` return one stale answer instead of N
    # fresh ones, defeating the whole point of exploration.
    (( alts > 1 )) && use_cache=0

    if (( use_cache )) && [[ -f "$cache_file" ]]; then
      cmd=$(< "$cache_file")
      cached=1
    fi

    # ── Status line + stream (skip stream on cache hit) ──
    if (( cached )); then
      printf '\033[2m%s ▸ %s ▸ %s ▸ cached\033[0m\n' "$provider" "$model" "$mode"
      printf '\033[1;33m%s\033[0m\n' "$cmd"
      if (( debug )); then
        _ask_debug_context
        _ask_debug_request
        {
          print -- '── ask: cache ──'
          printf 'hit: %s\n\n' "$cache_file"
        } >&2
      fi
    else
      if (( alts > 1 && retry == 0 && refine == 0 )); then
        printf '\033[2m%s ▸ %s ▸ %s ▸ %d alts\033[0m\n' \
          "$provider" "$model" "$mode" "$alts"
      else
        printf '\033[2m%s ▸ %s ▸ %s\033[0m\n' "$provider" "$model" "$mode"
      fi

      # Spinner-then-stream. The background pipeline parses SSE deltas
      # into $buf as they land; we spin while empty, then either drain
      # via typewriter (single) or wait for completion (alts).
      local cmd_buf="" cancelled=0 pipe_pid=
      raw=$(mktemp) || return 1
      buf=$(mktemp) || return 1
      net_err=$(mktemp) || return 1

      if (( debug )); then
        _ask_debug_context
        _ask_debug_request
      fi

      # Trap installed BEFORE backgrounding so a Ctrl+C in the gap
      # can't orphan curl. Sentinel guard on $pipe_pid handles the
      # case where SIGINT arrives before $! has been assigned.
      trap 'cancelled=1; [[ -n "$pipe_pid" ]] && kill "$pipe_pid" 2>/dev/null' INT

      _ask_stream "$url" headers "$body" "$stream_filter" "$mode" "$buf" "$raw" "$net_err"
      _ask_spinner_wait "$pipe_pid" "$buf" "$alts" "$retry" "$refine"

      if (( cancelled )); then
        rm -f -- "$raw" "$buf" "$net_err"; raw=""; buf=""; net_err=""
        trap - INT
        return 130
      fi

      # Typewriter replay so streaming feels consistent across modes
      # (smart-mode emission is so fast it would look like a burst).
      # Skipped in alts mode — sentinel lines streaming past would
      # just be visual noise; the picker is where the user engages.
      if (( alts > 1 && retry == 0 && refine == 0 )); then
        :
      elif [[ -s "$buf" ]] || kill -0 "$pipe_pid" 2>/dev/null; then
        printf '\033[1;33m'
        _ask_typewriter "$buf" "$pipe_pid"
        printf '\033[0m\n'
      fi

      trap - INT

      if (( cancelled )); then
        rm -f -- "$raw" "$buf" "$net_err"; raw=""; buf=""; net_err=""
        return 130
      fi

      if (( debug )); then
        _ask_debug_response "$raw" "$buf" "$net_err"
      fi

      cmd_buf=$(< "$buf")
      rm -f -- "$buf"; buf=""

      if [[ -z "$cmd_buf" ]]; then
        local err_info err_kind err_msg
        err_info=$(_ask_check_curl_exit "$raw" "$net_err")
        err_kind=${err_info%%$'\t'*}
        err_msg=${err_info#*$'\t'}
        rm -f -- "$raw" "$net_err"; raw=""; net_err=""
        case "$err_kind" in
          network) _ask_net_die "$err_msg"   ;;
          api)   _ask_api_die "$err_msg"   ;;
          parse) _ask_parse_die "$err_msg" ;;
          *)     _ask_die "$err_msg"       ;;
        esac
        return 1
      fi
      rm -f -- "$raw" "$net_err"; raw=""; net_err=""

      if (( alts > 1 && retry == 0 && refine == 0 )); then
        cmd=$(_ask_parse_alts "$cmd_buf" "$alts") || return 1
        if [[ -z "$cmd" ]]; then
          # \r\033[K clobbers any spinner remnant, then prints on a
          # clean line.
          printf '\r\033[K\033[2mask: no selection — aborted\033[0m\n' >&2
          return 0
        fi
        printf '\033[1;33m%s\033[0m\n' "$cmd"
      else
        cmd=$(_ask_clean_command "$cmd_buf")
        [[ -z "$cmd" ]] && { _ask_die 'no command returned'; return 1; }
      fi

      # Cache the cleaned single-answer command. Alts results never
      # cached (use_cache=0 was forced upstream).
      (( use_cache && alts == 1 )) && _ask_save_to_cache "$cache_dir" "$cache_file" "$cmd"
    fi

    # ── Confirm prompt (mutates next_action) ───────────
    _ask_confirm
  done

  [[ "$next_action" == "abort" ]] && return 0

  # ── Push to history (sans trailing # comment) ──────
  # So up-arrow recall gives a clean command body. Same [#] idiom as
  # the edit-mode strip. Skip if cmd is empty (user cleared it in
  # vared) so we don't pollute history with blanks.
  local hist_cmd="${cmd% [#]*}"
  hist_cmd="${hist_cmd%"${hist_cmd##*[![:space:]]}"}"
  [[ -n "$hist_cmd" ]] && print -s -- "$hist_cmd"

  # ── Eval with stderr capture for retry replay ──────
  # FD-juggling kept INLINE — extracting to a helper would break in two
  # ways: (a) NO_MULTIOS is function-scoped, so a helper would re-enable
  # MULTIOS and the helper procs hijack pipestatus[1]; (b) pipestatus[1]
  # in the helper would read the helper's last pipeline, not eval's.
  # Inside: 3>&1 saves the pipe, 1>&4 routes eval's stdout back to the
  # terminal, 2>&3 routes stderr through tee — which fans out to the
  # terminal's stderr and to err_file. pipestatus[1] is captured INSIDE
  # the braces because `} 4>&1` reassigns pipestatus once finalized.
  local rc
  err_file=$(mktemp 2>/dev/null)
  if [[ -n "$err_file" ]]; then
    { eval "$cmd" 3>&1 1>&4 2>&3 | tee -- "$err_file" >&2
      rc=${pipestatus[1]}
    } 4>&1
    _ask_record_attempt "$cache_dir" "$cmd" "$err_file" "$rc" "$original_task"
    rm -f -- "$err_file"; err_file=""
  else
    eval "$cmd"
    rc=$?
  fi
  return $rc
}


alias "?"="noglob ask";
alias "??"="noglob ask --smart";
