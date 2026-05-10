# AI shell-command generator: `? find files larger than 1GB`
# Aliased to `?` in shell.nix (with noglob, since ? is a zsh glob char).
# Supports Gemini, OpenAI, and Claude. Set one of:
#   GEMINI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY
# Pick provider with -g / -o / -c, override model with -m. See `? -h`.

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
  -g, --gemini          Google Gemini      (env: GEMINI_API_KEY,    model: gemini-3-flash-preview)
  -o, --openai          OpenAI             (env: OPENAI_API_KEY,    model: gpt-5.4-mini)
  -c, --claude          Anthropic Claude   (env: ANTHROPIC_API_KEY, model: claude-sonnet-4-6)
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
  -d, --debug           Print request URL/body and raw response to stderr
  -h, --help            Show this help

Auto-detect order: gemini > claude > openai.
Default model overrides: $GEMINI_MODEL, $OPENAI_MODEL, $ANTHROPIC_MODEL.

Aliases:
  ?    fast mode  (= ask)
  ??   smart mode (= ask --smart)

Examples:
  ? find files larger than 1GB
  ?? design a one-liner to dedupe by hash and keep newest
  ? -c port-forward 8080 to my staging cluster
  ? -o -m gpt-5.4 convert all png files in this dir to webp
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

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ask"

  # ── Parse flags ──────────────────────────────────────
  local provider="" model="" mode="${ASK_MODE:-fast}" use_cache=1 use_context=1 debug=0 explain=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)      _ask_help; return 0 ;;
      -g|--gemini|--google)    provider=gemini; shift ;;
      -o|--openai|--gpt|-gpt)    provider=openai; shift ;;
      -c|--claude)    provider=claude; shift ;;
      -p|--provider)  provider="$2"; shift 2 ;;
      -m|--model)     model="$2";    shift 2 ;;
      -s|--smart)     mode=smart; shift ;;
      -f|--fast)      mode=fast;  shift ;;
      -d|--debug)     debug=1; shift ;;
      -e|--explain)   explain=1; shift ;;
      --no-cache)     use_cache=0; shift ;;
      --clear-cache)  rm -rf -- "$cache_dir"; echo 'ask: cache cleared'; return 0 ;;
      --no-context)   use_context=0; shift ;;
      --)             shift; break ;;
      -*)             echo "ask: unknown flag: $1 (try -h)" >&2; return 1 ;;
      *)              break ;;
    esac
  done

  # Read piped stdin as context (e.g. `git status | ? what next`).
  # `[[ -t 0 ]]` is true when stdin is a terminal — i.e. nothing piped.
  # Capped at 32KB so `cat /var/log/syslog | ?` doesn't ship megabytes
  # to the API and blow the context budget. Prefer head over tail
  # because the start of a log/diff is usually more diagnostic than
  # the tail (which often repeats the last error).
  local stdin_data=""
  [[ ! -t 0 ]] && stdin_data=$(head -c 32768)

  # Dedicated fd for interactive prompts. Bound to the controlling tty
  # ($TTY = /dev/pts/N from zsh; /dev/tty fallback) so the confirm and
  # refine reads below are immune to stdin getting consumed by a pipe,
  # closed by the streaming pipeline, or otherwise hijacked. Closed at
  # function exit via the LOCAL_TRAPS-scoped EXIT trap. If neither tty
  # is openable (CI, no controlling terminal), fd 9 stays unbound and
  # the reads hit EOF → silent decline, which is the safe fallback.
  exec 9<"${TTY:-/dev/tty}" 2>/dev/null
  # Single EXIT trap covers fd 9 and any temp files created later.
  # The variables ($raw, $buf, $err_file) are function-locals declared
  # downstream; when the trap fires, unset ones expand empty and `rm
  # -f --` ignores them. Catches both clean exits and aborts (Ctrl+C
  # mid-eval, early `return`s) without per-path duplicated cleanup.
  local raw="" buf="" err_file=""
  trap 'rm -f -- "$raw" "$buf" "$err_file" 2>/dev/null; exec 9<&- 2>/dev/null' EXIT

  local task="$*"
  local user_task="$task"
  local retry=0 refine=0 original_task=""
  local attempts_file="$cache_dir/.last_attempts.jsonl"

  # Bare `?` (no args, no stdin) within 10 min of a failed command
  # triggers retry mode: feed the original intent + the last 3 failed
  # attempts (each cmd + stderr) back to the model so it can fix what
  # broke without re-cycling through approaches it already tried.
  if [[ -z "$task" && -z "$stdin_data" ]]; then
    if [[ -f "$attempts_file" ]] \
       && [[ -n "$(find "$attempts_file" -mmin -10 2>/dev/null)" ]]; then
      local last_task attempts_text
      last_task=$(< "$cache_dir/.last_task" 2>/dev/null)
      # jq -s slurps the JSONL stream into an array; we then format
      # each attempt with a 1-based index so the model can refer to
      # them ("attempt 2 fixed X but reintroduced Y").
      attempts_text=$(jq -r -s 'to_entries
        | map("attempt \(.key+1):\n  command: \(.value.cmd)\n  stderr: \(.value.stderr)")
        | join("\n\n")' < "$attempts_file" 2>/dev/null)
      task=$'original intent:\n'"${last_task:-(unknown)}"$'\n\nfailed prior attempts (oldest first):\n'"$attempts_text"$'\n\nproduce a corrected single command.'
      original_task="$last_task"
      use_cache=0
      retry=1
      # Show the user *what* we're retrying so they can confirm the
      # right context got carried over (and hit Ctrl+C if it didn't).
      local indicator="${last_task:-failed command}"
      (( ${#indicator} > 80 )) && indicator="${indicator:0:77}..."
      printf '\033[2mretrying: %s\033[0m\n' "$indicator"
    else
      _ask_help >&2
      return 1
    fi
  else
    # Fresh task: merge stdin into the prompt as labelled context so
    # the model can tell "what the user said" from "what they piped".
    if [[ -n "$stdin_data" ]]; then
      task=$'<stdin context>\n'"$stdin_data"$'\n</stdin context>\n\nuser intent: '"${user_task:-(figure out what to do with the stdin context)}"
    fi
    # original_task = what we'd show in a future retry indicator and
    # save to .last_task. Prefer typed text; fall back to a stub if
    # the user only piped stdin so the indicator isn't blank.
    original_task="${user_task:-${stdin_data:+stdin context}}"
  fi

  # ── Auto-detect provider when no flag given ──────────
  if [[ -z "$provider" ]]; then
    provider="${ASK_PROVIDER:-}"
    [[ -z "$provider" && -n "$GEMINI_API_KEY"    ]] && provider=gemini
    [[ -z "$provider" && -n "$ANTHROPIC_API_KEY" ]] && provider=claude
    [[ -z "$provider" && -n "$OPENAI_API_KEY"    ]] && provider=openai
    if [[ -z "$provider" ]]; then
      echo 'ask: no API key found. Set GEMINI_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY.' >&2
      return 1
    fi
  fi

  # ── Detect cwd context (project stack + git branch) ─────
  # Computed once outside the loop because the cwd doesn't change mid
  # function. Prepended to `task` inside the loop, so refine/retry
  # rebuilds (which restart from `original_task`) keep the metadata
  # without us having to thread it through every rebuild path.
  local cwd_context=""
  (( use_context )) && cwd_context=$(_ask_context)

  # ── Iterative loop: re-enters when the user picks 'r' to refine ──
  # Wraps build-request → cache-lookup → stream → confirm. Refine
  # mutates `task` and `refine`, then `continue`s back to the top to
  # regenerate. Indentation kept at 2 spaces (no re-indent) to keep
  # this diff readable; zsh doesn't care.
  while true; do

  # Wrap task in the cwd-context envelope for this iteration. We do
  # this every loop turn (rather than baking it into `task` once)
  # because refine rebuilds `task` from `original_task`, which would
  # otherwise drop the context. `task_full` flows into the request
  # body and the cache key; `task` itself stays clean for rebuilds.
  local task_full="$task"
  [[ -n "$cwd_context" ]] && task_full=$'<cwd>'"$cwd_context"$'</cwd>\n\n'"$task"

  # ── Build provider-specific request ──────────────────
  local sys body url stream_filter max_tok
  sys=$(_ask_sys)
  if (( retry )); then
    sys+=$'\n\nRETRY MODE\nThe user message contains the original intent and one or more failed prior attempts (each with the command and its stderr). Diagnose from the stderrs, learn what already failed, and stay anchored to the original intent — do not drift toward a different goal. Output a single corrected command per the OUTPUT CONTRACT — no apology, no explanation, no acknowledgment of the prior failures.'
  elif (( refine )); then
    sys+=$'\n\nREFINE MODE\nThe user message contains the original intent, a previous candidate command, and a refinement directive from the user. Apply the refinement while preserving the original intent. Output a single corrected command per the OUTPUT CONTRACT — no apology, no explanation.'
  fi
  if (( explain )); then
    # Tack a why-comment onto the command. The `#` keeps it inert at
    # eval time, so the user gets a teaching note without affecting
    # execution. Cache key naturally diverges (sys is part of it).
    sys+=$'\n\nEXPLAIN MODE OVERRIDE
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
  # 500 is generous for a one-line shell command; smart mode needs
  # much more headroom because OpenAI's max_output_tokens is shared
  # between reasoning and visible output (Gemini same, Claude has a
  # separate budget hardcoded below). Explain mode adds room for the
  # trailing why comment.
  [[ $mode == smart ]] && max_tok=16000 || max_tok=500
  (( explain )) && max_tok=$(( max_tok + 200 ))
  local -a headers=(-H 'Content-Type: application/json')

  case "$provider" in
    gemini|google)
      [[ -z "$GEMINI_API_KEY" ]] && { echo 'ask: GEMINI_API_KEY not set' >&2; return 1; }
      model="${model:-${GEMINI_MODEL:-gemini-3-flash-preview}}"
      # Pass the API key via header rather than URL query param so the
      # key never appears in $url (and thus can't leak via xtrace,
      # debug-mode dumps, process listings, or screenshots).
      url="https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse"
      headers+=(-H "x-goog-api-key: $GEMINI_API_KEY")
      stream_filter='.candidates[0].content.parts[]? | select(.text != null) | .text'
      local g_level
      [[ $mode == smart ]] && g_level=high || g_level=low
      body=$(jq -n --arg s "$sys" --arg t "$task_full" --arg lvl "$g_level" --argjson mt "$max_tok" '{
        system_instruction: {parts: [{text: $s}]},
        contents: [{parts: [{text: $t}]}],
        generationConfig: {
          temperature: 0.2,
          maxOutputTokens: $mt,
          stopSequences: ["\n\n"],
          thinkingConfig: {thinkingLevel: $lvl}
        }
      }')
      ;;
    openai|chatgpt|gpt)
      [[ -z "$OPENAI_API_KEY" ]] && { echo 'ask: OPENAI_API_KEY not set' >&2; return 1; }
      model="${model:-${OPENAI_MODEL:-gpt-5.4-mini}}"
      url='https://api.openai.com/v1/responses'
      stream_filter='select(.type == "response.output_text.delta") | .delta'
      local o_effort
      [[ $mode == smart ]] && o_effort=high || o_effort=low
      body=$(jq -n --arg s "$sys" --arg t "$task_full" --arg m "$model" --arg e "$o_effort" --argjson mt "$max_tok" '{
        model: $m,
        max_output_tokens: $mt,
        reasoning: {effort: $e},
        instructions: $s,
        input: $t,
        stream: true
      }')
      headers+=(-H "Authorization: Bearer $OPENAI_API_KEY")
      ;;
    claude|anthropic)
      [[ -z "$ANTHROPIC_API_KEY" ]] && { echo 'ask: ANTHROPIC_API_KEY not set' >&2; return 1; }
      model="${model:-${ANTHROPIC_MODEL:-claude-sonnet-4-6}}"
      url='https://api.anthropic.com/v1/messages'
      # Filter only text deltas — skips thinking_delta in smart mode.
      stream_filter='select(.type == "content_block_delta" and .delta.type == "text_delta") | .delta.text'
      if [[ $mode == smart ]]; then
        # Extended thinking: requires no custom temperature, no
        # stop_sequences, and max_tokens > budget_tokens.
        body=$(jq -n --arg s "$sys" --arg t "$task_full" --arg m "$model" '{
          model: $m,
          max_tokens: 10000,
          thinking: {type: "enabled", budget_tokens: 5000},
          system: $s,
          messages: [{role: "user", content: $t}],
          stream: true
        }')
      else
        body=$(jq -n --arg s "$sys" --arg t "$task_full" --arg m "$model" --argjson mt "$max_tok" '{
          model: $m,
          max_tokens: $mt,
          temperature: 0.2,
          stop_sequences: ["\n\n"],
          system: $s,
          messages: [{role: "user", content: $t}],
          stream: true
        }')
      fi
      headers+=(
        -H "x-api-key: $ANTHROPIC_API_KEY"
        -H 'anthropic-version: 2023-06-01'
      )
      ;;
    *)
      echo "ask: unknown provider: $provider (use gemini, openai, or claude)" >&2
      return 1
      ;;
  esac

  # ── Cache lookup ─────────────────────────────────────
  # Trim leading/trailing whitespace from the task so trivial spacing
  # differences don't produce different cache keys.
  local task_key=${task_full#"${task_full%%[![:space:]]*}"}
  task_key=${task_key%"${task_key##*[![:space:]]}"}

  local cache_key cache_file cmd="" cached=0
  cache_key=$(printf '%s\n%s\n%s\n%s\n%s' \
    "$provider" "$model" "$mode" "$sys" "$task_key" \
    | sha256sum | cut -d' ' -f1)
  cache_file="$cache_dir/$cache_key"

  if (( use_cache )) && [[ -f "$cache_file" ]]; then
    cmd=$(< "$cache_file")
    cached=1
  fi

  # ── Status line (always first) ───────────────────────
  if (( cached )); then
    printf '\033[2m%s ▸ %s ▸ %s ▸ cached\033[0m\n' "$provider" "$model" "$mode"
    printf '\033[1;33m%s\033[0m\n' "$cmd"
  else
    printf '\033[2m%s ▸ %s ▸ %s\033[0m\n' "$provider" "$model" "$mode"

    # ── Spinner-then-stream ──────────────────────────
    # Background pipeline parses the SSE stream and writes the
    # concatenated text deltas to $buf as they land.
    # Foreground:
    #   1. Spin "thinking…" while $buf is empty (waiting for first
    #      delta) and the pipeline is still alive.
    #   2. Once $buf has any data, clear the spinner and tail-follow
    #      $buf so deltas appear live, in pieces, until pipe dies.
    local cmd_buf="" cancelled=0 pipe_pid
    raw=$(mktemp) || return 1
    buf=$(mktemp) || return 1

    # `&!` = background + disown immediately. With MONITOR on (needed
    # for reads to work post-pipeline), a plain `&` would print the
    # job-table announce/done lines into the user's terminal. Disowning
    # drops it from the job table so those notifications never fire;
    # we still get $! and can poll with `kill -0` for completion.
    # Smart mode needs a longer ceiling because thinking budgets push
    # generation past the default 60s for some prompts.
    local curl_max=60
    [[ $mode == smart ]] && curl_max=180
    # Trap installed BEFORE backgrounding so a Ctrl+C in the gap can't
    # orphan curl. Sentinel guard on $pipe_pid handles the case where
    # SIGINT arrives before $! has been assigned.
    pipe_pid=
    trap 'cancelled=1; [[ -n "$pipe_pid" ]] && kill "$pipe_pid" 2>/dev/null' INT
    {
      curl -sS -N --fail-with-body --connect-timeout 10 --max-time "$curl_max" \
        "$url" "${headers[@]}" -d "$body" 2>/dev/null \
      | tee -- "$raw" \
      | grep --line-buffered '^data: ' \
      | sed -u 's/^data: //' \
      | jq --unbuffered -j "$stream_filter" 2>/dev/null \
      > "$buf"
    } &!
    pipe_pid=$!

    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' fi=0
    while kill -0 "$pipe_pid" 2>/dev/null && [[ ! -s "$buf" ]]; do
      printf '\r\033[1;36m%s\033[0m thinking…' "${frames:$fi:1}"
      (( fi = (fi + 1) % ${#frames} ))
      sleep 0.08
    done
    printf '\r\033[K'

    if (( cancelled )); then
      rm -f -- "$raw" "$buf"
      trap - INT
      return 130
    fi

    # Typewriter replay so streaming feels consistent across modes —
    # in smart mode the actual text emission is so fast it would
    # otherwise look like a burst. Paces ~10ms/char regardless of
    # whether the pipe is still streaming or already done. The polling
    # via `kill -0` inside ensures we exit only when the bg pipe is
    # gone — no `wait` needed (the disowned `&!` job isn't waitable).
    if [[ -s "$buf" ]] || kill -0 "$pipe_pid" 2>/dev/null; then
      printf '\033[1;33m'
      _ask_typewriter "$buf" "$pipe_pid"
      printf '\033[0m\n'
    fi

    trap - INT

    if (( cancelled )); then
      rm -f -- "$raw" "$buf"
      return 130
    fi

    if (( debug )); then
      print -u2 -- '── ask: request ──'
      # Gemini puts the API key in the URL — redact before printing.
      print -u2 -- "URL: ${url//key=*/key=REDACTED}"
      print -u2 -r -- "$body"
      print -u2 -- '── ask: raw response ──'
      cat -- "$raw" >&2
      print -u2 -- ''
    fi

    cmd_buf=$(< "$buf")
    rm -f -- "$buf"

    if [[ -z "$cmd_buf" ]]; then
      local err
      err=$(jq -r '.error.message // .error // empty' < "$raw" 2>/dev/null)
      rm -f -- "$raw"
      if [[ -n "$err" ]]; then
        echo "ask: API error: $err" >&2
      else
        echo "ask: no command returned" >&2
      fi
      return 1
    fi
    rm -f -- "$raw"

    # Strip stray markdown fences so eval gets just the command.
    # The streamed display showed the raw form; cache + eval get
    # the cleaned form. We do NOT touch individual backticks —
    # that would break legitimate `pwd`-style command substitution.
    # sed handles any language tag (bash/Bash/python/...), tilde
    # fences (~~~), and surrounding whitespace robustly. Per-line
    # match: opening fence on first line only, closing fence on
    # last line only, so a stray ``` inside a heredoc body would be
    # preserved (rare, but worth noting).
    # Backticks are NOT escaped here. `\`` in GNU sed regex is a
    # zero-width match (backslash before non-meta is undefined; GNU
    # treats it as nothing), which made the alternation match empty
    # at start of line — and then `[[:alnum:]]*[[:space:]]*` happily
    # ate the first word + space, stripping `ls ` from `ls -lh ...`.
    # Backticks aren't special in single quotes or in regex, so just
    # write them literally.
    cmd=$(printf '%s' "$cmd_buf" \
      | sed -E '1{s/^[[:space:]]*(```|~~~)[[:alnum:]]*[[:space:]]*$//; s/^[[:space:]]*(```|~~~)[[:alnum:]]*[[:space:]]*//}; ${s/[[:space:]]*(```|~~~)[[:space:]]*$//}')
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    # Strip a leading "$ " or "% " prompt char if the model slipped.
    [[ "$cmd" == '$ '* || "$cmd" == '% '* ]] && cmd="${cmd:2}"

    if [[ -z "$cmd" ]]; then
      echo 'ask: no command returned' >&2
      return 1
    fi

    # Save the cleaned command so cache hits don't re-run cleanup.
    # Write to a sibling tempfile then rename — rename(2) is atomic
    # within the same filesystem, so concurrent ? calls on the same
    # key can't tear each other's writes.
    if (( use_cache )) && mkdir -p -- "$cache_dir"; then
      local tmp_save
      tmp_save=$(mktemp "$cache_dir/.tmp.XXXXXX") \
        && printf '%s' "$cmd" > "$tmp_save" \
        && mv -f -- "$tmp_save" "$cache_file" \
        || rm -f -- "$tmp_save"
    fi
  fi

  # ── Confirm prompt ────────────────────────────────────────
  # Compact colored options: green y (run), bold-red N (default —
  # plain Enter declines), blue e (edit), yellow r (refine), dim ?
  # (inline help). Inner loop reprompts after `?` so help doesn't
  # bounce the user out. break 2 / continue 2 walk back out to the
  # iterative loop that wraps build/cache/stream.
  local confirm
  while true; do
    printf '\033[1;37mRun?\033[0m [\033[32my\033[0m/\033[1;31mn\033[0m/\033[34me\033[0m/\033[33mr\033[0m/\033[2m?\033[0m] '
    read -r -u 9 confirm
    case "$confirm" in
      [Yy]*) break 2 ;;
      [Ee]*)
        # Strip any trailing " # ..." comment before editing — explain
        # mode's why-note (and any stray model comment) just clutters
        # the edit. The leading space anchors it (so a "#" inside a
        # token like awk's "#" isn't matched), and [#] keeps the # a
        # literal under EXTENDED_GLOB (where bare # is a postfix op).
        cmd="${cmd% [#]*}"
        cmd="${cmd%"${cmd##*[![:space:]]}"}"
        # vared drops you into zsh's line editor on $cmd for an
        # in-place tweak (path, flag, etc.) before running.
        vared cmd
        # Persist the user's edit to cache so next identical query
        # returns their fix, not the AI's original. Trade-off: a
        # run-specific tweak (e.g. a one-off path) gets baked in;
        # users can `--no-cache` or `--clear-cache` to redo.
        if (( use_cache )) && [[ -n "$cmd" ]] \
           && mkdir -p -- "$cache_dir" 2>/dev/null; then
          printf '%s' "$cmd" | _ask_save "$cache_file"
        fi
        break 2
        ;;
      [Rr]*)
        # Refine: re-prompt the model with the original intent + the
        # current candidate + the user's directive, then loop back to
        # the build/cache/stream stage with the new task.
        printf '\033[2mrefine: \033[0m'
        local refinement
        read -r -u 9 refinement
        if [[ -z "$refinement" ]]; then
          echo 'ask: empty refinement, cancelling' >&2
          return 0
        fi
        # Strip the explain-mode why-comment from the previous cmd so
        # the model gets only the executable part as context.
        local prev_cmd="${cmd% [#]*}"
        prev_cmd="${prev_cmd%"${prev_cmd##*[![:space:]]}"}"
        task=$'original intent:\n'"${original_task:-(unknown)}"$'\n\nprevious candidate:\n'"$prev_cmd"$'\n\nrefinement:\n'"$refinement"$'\n\nproduce a corrected single command.'
        use_cache=0
        refine=1
        retry=0
        continue 2
        ;;
      '?'|h|H|help)
        # Inline cheat-sheet, then reprompt. Quoted '?' so the case
        # pattern matches a literal `?` rather than any single char.
        printf '\033[2m  y\033[0m  run the command\n'
        printf '\033[2m  n\033[0m  decline (default — plain Enter also works)\n'
        printf '\033[2m  e\033[0m  edit the command before running\n'
        printf '\033[2m  r\033[0m  refine: rewrite with a follow-up directive\n'
        continue
        ;;
      *) return 0 ;;
    esac
  done
  done  # ── end iterative loop ──
  # Push to shell history WITHOUT any trailing "# why: ..." comment,
  # so up-arrow recall gives a clean command body. Same [#] idiom as
  # the edit-mode strip — the leading space anchors it so a literal
  # "#" inside a token isn't matched. Skip if cmd is empty (user
  # cleared it in vared) so we don't pollute history with blanks.
  local hist_cmd="${cmd% [#]*}"
  hist_cmd="${hist_cmd%"${hist_cmd##*[![:space:]]}"}"
  [[ -n "$hist_cmd" ]] && print -s -- "$hist_cmd"

  # Capture stderr to a tempfile while keeping it live for the user,
  # so a follow-up bare `?` can feed the error back to the model.
  # Pipe-with-fd-juggling instead of `2> >(tee ...)`: the latter is a
  # process substitution registered in zsh's job table, so flushing it
  # would require `wait`, which without an explicit PID blocks on every
  # other background job in the user's shell. The pipeline tears down
  # synchronously and we read pipestatus[1] for eval's real exit code.
  # Inside: 3>&1 saves the pipe, 1>&4 redirects eval's stdout back to
  # the terminal, 2>&3 routes stderr through the pipe to tee — which
  # fans out to the terminal's stderr and to err_file.
  local rc
  err_file=$(mktemp 2>/dev/null)
  if [[ -n "$err_file" ]]; then
    # pipestatus[1] is captured *inside* the braces because the outer
    # block's exit reassigns pipestatus once `} 4>&1` finalizes.
    { eval "$cmd" 3>&1 1>&4 2>&3 | tee -- "$err_file" >&2
      rc=${pipestatus[1]}
    } 4>&1

    mkdir -p -- "$cache_dir" 2>/dev/null
    if (( rc != 0 )) && [[ -d "$cache_dir" ]]; then
      # Append the new failure to .last_attempts.jsonl, keeping only
      # the last 3 entries so retries see a bounded history. jq -nc
      # builds a compact JSON line with proper escaping for cmd/stderr.
      # Stderr trimmed to last 4KB — long compiler/test dumps would
      # blow the next prompt budget otherwise.
      local entry
      entry=$(jq -nc --arg cmd "$cmd" \
        --arg err "$(tail -c 4096 -- "$err_file" 2>/dev/null)" \
        '{cmd:$cmd, stderr:$err}')
      {
        tail -n 2 "$attempts_file" 2>/dev/null
        printf '%s\n' "$entry"
      } | _ask_save "$attempts_file"
      printf '%s' "$original_task" | _ask_save "$cache_dir/.last_task"
    else
      rm -f -- "$attempts_file" "$cache_dir/.last_task" 2>/dev/null
      # Tidy up the legacy single-attempt files from the older format
      # if a user is upgrading. Harmless if absent.
      rm -f -- "$cache_dir/.last_cmd" "$cache_dir/.last_stderr" 2>/dev/null
    fi
    rm -f -- "$err_file"
  else
    eval "$cmd"
    rc=$?
  fi
  return $rc
}


alias "?"="noglob ask";
alias "??"="noglob ask --smart";