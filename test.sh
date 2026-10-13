#!/usr/bin/env bash
# Tests for cca. Runs against a throwaway HOME and a fake `claude` binary.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CCA="$HERE/cca"
PASS=0 FAIL=0

setup() {
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$HOME/.claude/skills" "$HOME/.claude/projects" "$T/bin"
  echo '# shared' >"$HOME/.claude/CLAUDE.md"
  echo '{}' >"$HOME/.claude/settings.json"
  echo 'SECRET' >"$HOME/.claude/.credentials.json"
  # Fake claude: records config dir, args and one env var.
  cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "dir=${CLAUDE_CONFIG_DIR:-<unset>}"; echo "args=$*"; echo "key=${ANTHROPIC_API_KEY:-<unset>}"; printf 'argv=%s\n' "$@"; } >"$HOME/claude.log"
EOF
  chmod +x "$T/bin/claude"
  export PATH="$T/bin:/usr/bin:/bin"
  ACC="$HOME/.claude-accounts"
  export CCA_SAFE=1
}
teardown() { rm -rf "$T"; }
log() { cat "$HOME/claude.log" 2>/dev/null; }
args() { sed -n 's/^args=//p' "$HOME/claude.log" 2>/dev/null; }
argv() { sed -n 's/^argv=//p' "$HOME/claude.log" 2>/dev/null; }

check() { # name, condition-command...
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   $name"; else FAIL=$((FAIL + 1)); echo "FAIL $name"; fi
}
has() { [[ "$1" == *"$2"* ]]; }

t_default_runs_without_config_dir() {
  "$CCA" default -c >/dev/null
  check "default: no CLAUDE_CONFIG_DIR" has "$(log)" "dir=<unset>"
  check "default: args passed through" test "$(args)" = "-c"
}

t_add_creates_account_and_launches_login() {
  "$CCA" add work >/dev/null 2>&1
  check "add: dir created" test -d "$ACC/work"
  check "add: CLAUDE.md symlinked" test -L "$ACC/work/CLAUDE.md"
  check "add: skills symlinked" test -L "$ACC/work/skills"
  check "add: credentials NOT shared" test ! -e "$ACC/work/.credentials.json"
  check "add: launched with config dir" has "$(log)" "dir=$ACC/work"
  check "add: dir is private (700)" test "$(stat -c %a "$ACC/work")" = 700
}

t_add_rejects_bad_name() {
  "$CCA" add ../evil >/dev/null 2>&1
  check "add: bad name rejected" test $? -ne 0
  check "add: nothing created outside" test ! -e "$HOME/evil"
}

t_add_rejects_existing() {
  "$CCA" add work >/dev/null 2>&1
  "$CCA" add work >/dev/null 2>&1
  check "add: duplicate rejected" test $? -ne 0
  "$CCA" add default >/dev/null 2>&1
  check "add: 'default' reserved" test $? -ne 0
}

t_run_named_account() {
  "$CCA" add work >/dev/null 2>&1
  "$CCA" work --resume abc >/dev/null
  check "run: config dir set" has "$(log)" "dir=$ACC/work"
  check "run: args passed" test "$(args)" = "--resume abc"
}

t_run_unknown_account_fails() {
  "$CCA" nope >/dev/null 2>&1
  check "run: unknown account fails" test $? -ne 0
}

t_env_file_is_loaded() {
  "$CCA" add api >/dev/null 2>&1
  echo 'ANTHROPIC_API_KEY=k-123' >"$ACC/api/env"
  "$CCA" api >/dev/null
  check "env: loaded and exported" has "$(log)" "key=k-123"
}

t_ls_shows_accounts_and_email() {
  "$CCA" add work >/dev/null 2>&1
  echo '{"oauthAccount":{"emailAddress":"w@x.io"}}' >"$ACC/work/.claude.json"
  echo '{"oauthAccount":{"emailAddress":"me@x.io"}}' >"$HOME/.claude.json"
  local out; out="$("$CCA" ls)"
  check "ls: default listed with email" has "$out" "me@x.io"
  check "ls: work listed with email" has "$out" "w@x.io"
}

t_ls_ignores_symlinks() {
  "$CCA" add work >/dev/null 2>&1
  ln -s "$HOME/.claude/skills" "$ACC/skills"
  check "ls: symlinked dir not listed" bash -c '! "$0" ls | grep -q "^skills "' "$CCA"
}

t_picker_selects_by_number() {
  "$CCA" add work >/dev/null 2>&1
  printf '2\n' | "$CCA" >/dev/null 2>&1
  check "picker: 2nd entry (work) chosen" has "$(log)" "dir=$ACC/work"
}

t_picker_cancel_does_not_launch() {
  "$CCA" add work >/dev/null 2>&1; rm -f "$HOME/claude.log"
  "$CCA" </dev/null >/dev/null 2>&1
  check "picker cancel: exits non-zero" test $? -ne 0
  check "picker cancel: claude not launched" test ! -e "$HOME/claude.log"
  check "picker cancel: no claude files in accounts root" test ! -e "$ACC/CLAUDE.md"
}

t_run_rejects_path_names() {
  "$CCA" add work >/dev/null 2>&1; rm -f "$HOME/claude.log"; mkdir -p "$HOME/elsewhere"
  "$CCA" ../elsewhere >/dev/null 2>&1
  check "run: path-like name rejected" test $? -ne 0
  check "run: claude not launched for path" test ! -e "$HOME/claude.log"
}

t_rm_requires_confirmation() {
  "$CCA" add work >/dev/null 2>&1
  printf 'n\n' | "$CCA" rm work >/dev/null 2>&1
  check "rm: kept on 'n'" test -d "$ACC/work"
  printf 'y\n' | "$CCA" rm work >/dev/null 2>&1
  check "rm: removed on 'y'" test ! -e "$ACC/work"
  check "rm: shared source untouched" test -f "$HOME/.claude/CLAUDE.md"
  "$CCA" rm default </dev/null >/dev/null 2>&1
  check "rm: default refused" test $? -ne 0
}

t_rename() {
  "$CCA" add work >/dev/null 2>&1
  "$CCA" rename work job >/dev/null
  check "rename: new exists" test -d "$ACC/job"
  check "rename: old gone" test ! -e "$ACC/work"
}

t_rename_default_sets_display_name() {
  "$CCA" rename default work >/dev/null 2>&1
  check "rename default: login dir untouched" test -f "$HOME/.claude/.credentials.json"
  "$CCA" work -c >/dev/null 2>&1
  check "rename default: new name launches default" has "$(log)" "dir=<unset>"
  rm -f "$HOME/claude.log"
  "$CCA" default >/dev/null 2>&1
  check "rename default: 'default' still works" has "$(log)" "dir=<unset>"
  check "rename default: ls shows new name" has "$("$CCA" ls)" "work"
  printf '1\n' | "$CCA" >/dev/null 2>&1
  check "rename default: picker entry 1 is default" has "$(log)" "dir=<unset>"
  "$CCA" rm work </dev/null >/dev/null 2>&1
  check "rename default: rm by new name refused" test $? -ne 0
  "$CCA" add work >/dev/null 2>&1
  check "rename default: add with same name refused" test $? -ne 0
}

t_rename_default_clash_rejected() {
  "$CCA" add job >/dev/null 2>&1
  "$CCA" rename default job >/dev/null 2>&1
  check "rename default: clash with account rejected" test $? -ne 0
}

t_rename_default_back() {
  "$CCA" rename default work >/dev/null 2>&1
  "$CCA" rename work me >/dev/null 2>&1
  check "rename default: rename again" has "$("$CCA" ls)" "me "
  "$CCA" rename me default >/dev/null 2>&1
  check "rename default: reset to 'default'" has "$("$CCA" ls)" "default "
}

t_help_shows_only_header() {
  local out; out="$("$CCA" help)"
  check "help: mentions --safe" has "$out" "--safe"
  check "help: says bypass is default" has "$out" "Default: claude runs with --dangerously-skip-permissions"
  check "help: no code leaks" bash -c '! grep -q "set -e" <<<"$0"' "$out"
}

B=--dangerously-skip-permissions
# Claude was launched (fresh log) with exactly these args.
ran_with() { [[ -e "$HOME/claude.log" ]] && [[ "$(args)" == "$1" ]]; }
t_bypass_is_default() {
  unset CCA_SAFE; "$CCA" default -c >/dev/null 2>&1
  check "bypass: added by default" ran_with "$B -c"
  "$CCA" add work >/dev/null 2>&1
  check "bypass: add launches with flag" ran_with "$B"
  rm -f "$HOME/claude.log"; "$CCA" work -c >/dev/null 2>&1
  check "bypass: named account gets flag" ran_with "$B -c"
  rm -f "$HOME/claude.log"; printf '2\n' | "$CCA" >/dev/null 2>&1
  check "bypass: picker gets flag" ran_with "$B"
  check "bypass: picker chose work" has "$(log)" "dir=$ACC/work"
  rm -f "$HOME/claude.log"; "$CCA" default -p "a b" c >/dev/null 2>&1
  check "bypass: args keep spaces and order" test "$(argv)" = "$(printf '%s\n' "$B" -p "a b" c)"
}

t_bypass_safe_flag() {
  unset CCA_SAFE; "$CCA" add work >/dev/null 2>&1; rm -f "$HOME/claude.log"
  rm -f "$HOME/claude.log"; "$CCA" --safe work -c >/dev/null 2>&1
  check "bypass: --safe + name omits flag" ran_with "-c"
  rm -f "$HOME/claude.log"; printf '2\n' | "$CCA" --safe >/dev/null 2>&1
  check "bypass: --safe + picker omits flag" ran_with ""
  check "bypass: --safe + picker chose work" has "$(log)" "dir=$ACC/work"
  echo 'SAFE=0' >"$ACC/work/env"
  rm -f "$HOME/claude.log"; "$CCA" --safe work >/dev/null 2>&1
  check "bypass: env file cannot override --safe" bash -c '! [ -e "$0" ] || grep -qx "args=" "$0"' "$HOME/claude.log"
  echo 'flags=()' >"$ACC/work/env"; unset CCA_SAFE
  rm -f "$HOME/claude.log"; "$CCA" work >/dev/null 2>&1
  check "bypass: env file cannot clear the flag list" bash -c '! [ -e "$0" ] || grep -qx "args=--dangerously-skip-permissions" "$0"' "$HOME/claude.log"
  rm -f "$ACC/work/env"
  rm -f "$HOME/claude.log"; "$CCA" --safe add other >/dev/null 2>&1
  check "bypass: --safe + add omits flag" ran_with ""
  rm -f "$HOME/claude.log"; "$CCA" work --safe >/dev/null 2>&1
  check "bypass: later --safe goes to claude" ran_with "$B --safe"
}

t_bypass_env() {
  rm -f "$HOME/claude.log"; CCA_SAFE=1 "$CCA" default >/dev/null 2>&1
  check "bypass: CCA_SAFE=1 omits flag" ran_with ""
  rm -f "$HOME/claude.log"; CCA_SAFE=0 "$CCA" default >/dev/null 2>&1
  check "bypass: CCA_SAFE=0 keeps flag" ran_with "$B"
  rm -f "$HOME/claude.log"; CCA_SAFE= "$CCA" default >/dev/null 2>&1
  check "bypass: empty CCA_SAFE keeps flag" ran_with "$B"
}

t_bypass_user_flags_win() {
  unset CCA_SAFE; local f
  for f in "--permission-mode plan" "--permission-mode=plan" "$B" "--allow-dangerously-skip-permissions"; do
    rm -f "$HOME/claude.log"
    # shellcheck disable=SC2086
    "$CCA" default $f >/dev/null 2>&1
    check "bypass: user '$f' not doubled" ran_with "$f"
  done
}

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  setup; "$t"; teardown
done
echo "---"; echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
