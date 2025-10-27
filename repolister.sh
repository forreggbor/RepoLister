#!/bin/bash
# ------------------------------------------------------------
# RepoLister v0.1 - GitHub/Gitea RAW URL exporter with full TUI
# ------------------------------------------------------------
# DESCRIPTION
# RepoLister generates lists of RAW file URLs from GitHub or Gitea repos.
# It offers a full-screen TUI (dialog), Quick-Run, repository/profile
# management, private tokens, and a metadata header in each export.
#
# USAGE
# 1) Interactive TUI (recommended):
#       ./repolister.sh
#    - First run initializes folders & default configs via TUI.
#    - Manage repositories & profiles, run exports, view results.
#    - Quick-Run uses last or default profile + first repo.
#
# 2) CLI / cron mode (requires existing conf files):
#       ./repolister.sh --profile=default.conf --repo=<repo-id> [--branch=main] \
#                       [--format=txt|csv|json|html] [--keep] [--no-exclude] \
#                       [--include="\.php,\.js"] [--exclude="\.css"]
#    - Output directory is taken from profiles/default.conf (OUTPUT_DIR).
#    - Repo id refers to section name in repos.conf (e.g. [mozgasnaplo]).
#
# REQUIREMENTS
# - bash, git, dialog, jq
#   (Ubuntu/Debian)  : sudo apt-get install -y git dialog jq
#   (RHEL/CentOS/Fed): sudo dnf install -y git dialog jq
#
# FILE LAYOUT (created on first run)
#   ./repolister.sh
#   ./profiles/default.conf           # output dir, defaults
#   ./profiles/json-export.conf       # sample
#   ./profiles/gitea-private.conf     # sample
#   ./repos.conf                      # ini-style repo entries
#   ./tokens.conf                     # optional domain-wide tokens
#   ./exports/                        # all exports go here
#
# DEFAULT EXCLUDES (can be confirmed/disabled in TUI)
#   vendor/, .gitignore, LICENSE.md, *.mo, composer*, package*, .htaccess, favicon.ico
#   images/videos/audio: jpg, jpeg, png, gif, svg, bmp, webp, mp3, wav, ogg, mp4, mov, avi, mkv
# ------------------------------------------------------------

set -euo pipefail

APP_NAME="RepoLister"
BACKTITLE="$APP_NAME"
STATE_DIR="."
PROFILES_DIR="$STATE_DIR/profiles"
EXPORTS_DIR="$STATE_DIR/exports"
REPOS_FILE="$STATE_DIR/repos.conf"
TOKENS_FILE="$STATE_DIR/tokens.conf"
LAST_PROFILE_FILE="$STATE_DIR/.last_profile"
LAST_REPO_FILE="$STATE_DIR/.last_repo"

DEFAULT_EXCLUDE='(^vendor/|^vendor$|\.mo$|\.gitignore$|LICENSE\.md$|composer.*|package.*|\.htaccess$|favicon\.ico$|\.jpg$|\.jpeg$|\.png$|\.gif$|\.svg$|\.bmp$|\.webp$|\.mp3$|\.wav$|\.ogg$|\.mp4$|\.mov$|\.avi$|\.mkv$)'

# ---------- Utilities ----------
die(){ echo "Error: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
mkdirp(){ mkdir -p "$1"; }

dialog_cmd(){ dialog --backtitle "$BACKTITLE" "$@"; }
textbox(){ dialog_cmd --title "$1" --textbox "$2" 24 90; }
msg(){ dialog_cmd --msgbox "$1" 8 70; }
yesno(){ dialog_cmd --yesno "$1" 10 70; } # returns 0/1
infobox(){ dialog_cmd --infobox "$1" 5 60; }

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ; }

# Read INI-like section from repos.conf: [id] keys...
ini_get_section(){
  local file="$1" section="$2"
  awk -v sec="$section" '
    $0 ~ "^[[:space:]]*\\[" sec "\\][[:space:]]*$" { found=1; next }
    /^\[/ { if(found) exit } 
    found && $0 !~ /^[[:space:]]*#/ && length($0)>0 { print }
  ' "$file"
}

ini_set_section(){
  # Replace or append an entire [section] with provided lines on stdin
  local file="$1" section="$2" tmp="${file}.tmp.$$"
  awk -v sec="$section" -v RS= -v ORS="" '
    BEGIN{printed=0}
    {
      if ($0 ~ "\\[" sec "\\]") {
        if (!printed) {
          print "[" sec "]\n"
          while ((getline line < "/dev/stdin") > 0) print line "\n"
          printed=1
        }
      } else {
        print
      }
    }
    END{
      if (!printed) {
        print "\n[" sec "]\n"
        while ((getline line < "/dev/stdin") > 0) print line "\n"
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

list_sections(){
  awk '/^\[.*\]/{ gsub(/[\[\]]/,""); print $0 }' "$1"
}

# ---------- First-run initialization ----------
first_run(){
  local changed=0
  if [ ! -d "$PROFILES_DIR" ]; then mkdirp "$PROFILES_DIR"; changed=1; fi
  if [ ! -d "$EXPORTS_DIR" ]; then mkdirp "$EXPORTS_DIR"; changed=1; fi
  if [ ! -f "$REPOS_FILE" ]; then
    cat > "$REPOS_FILE" <<'EOF'
# repos.conf - define repositories to list
# Example:
# [mozgasnaplo]
# domain=github.com
# user=forreggbor
# repo=mozgasnaplo
# default_branch=main
# token=     # optional; overrides tokens.conf for this repo
EOF
    changed=1
  fi
  if [ ! -f "$TOKENS_FILE" ]; then
    cat > "$TOKENS_FILE" <<'EOF'
# tokens.conf - optional domain-wide tokens (used if repo.token not set)
# Format (bash): TOKEN_github_com="ghp_xxx"; TOKEN_gitea_example_local="abc123"
# Note: dots replaced by underscores in variable names.
EOF
    chmod 600 "$TOKENS_FILE" || true
    changed=1
  fi
  if [ ! -f "$PROFILES_DIR/default.conf" ]; then
    cat > "$PROFILES_DIR/default.conf" <<'EOF'
# ------------------------------------------------------------
# Default configuration profile for RepoLister
# Purpose:
#   Holds common defaults for TUI and CLI. OUTPUT_DIR is required for CLI/cron.
# How to set:
#   Use bash-style KEY="value" lines. Regex lists are comma-separated.
# ------------------------------------------------------------
DOMAIN="github.com"
FORMAT="csv"
OUTPUT_DIR="exports"
INCLUDE="\.php,\.js,\.css"
EXCLUDE=""           # empty means use internal default exclusions
KEEP=false
TOKEN=""             # optional personal token
EOF
    changed=1
  fi
  if [ ! -f "$PROFILES_DIR/json-export.conf" ]; then
    cat > "$PROFILES_DIR/json-export.conf" <<'EOF'
# ------------------------------------------------------------
# JSON export profile
# Purpose:
#   Generate file list as JSON for programmatic use.
# How to set:
#   Adjust DOMAIN/FORMAT/INCLUDE/EXCLUDE as needed.
# ------------------------------------------------------------
DOMAIN="github.com"
FORMAT="json"
OUTPUT_DIR="exports"
INCLUDE="\.php,\.js,\.css"
EXCLUDE=""
KEEP=true
TOKEN=""
EOF
    changed=1
  fi
  if [ ! -f "$PROFILES_DIR/gitea-private.conf" ]; then
    cat > "$PROFILES_DIR/gitea-private.conf" <<'EOF'
# ------------------------------------------------------------
# Gitea private repository profile
# Purpose:
#   Use with private Gitea repos; set TOKEN if not defined per-repo.
# How to set:
#   Provide DOMAIN, OUTPUT_DIR, optionally TOKEN.
# ------------------------------------------------------------
DOMAIN="gitea.example.local"
FORMAT="txt"
OUTPUT_DIR="exports"
INCLUDE="\.php,\.js"
EXCLUDE=""
KEEP=false
TOKEN=""   # e.g. "my_gitea_pat"
EOF
    changed=1
  fi
  return $changed
}

prompt_initial_setup(){
  # Called only on true first run to collect essentials
  local domain outdir user
  domain=$(dialog_cmd --stdout --inputbox "Enter default Git server domain (e.g., github.com):" 8 60 "github.com") || exit 1
  outdir=$(dialog_cmd --stdout --inputbox "Enter exports directory:" 8 60 "exports") || exit 1
  mkdirp "$outdir"
  # Write into profiles/default.conf
  awk -v od="$outdir" -v dm="$domain" '
    BEGIN{odq="\"" od "\""; dmq="\"" dm "\""}
    /^DOMAIN=/ {$0="DOMAIN=" dmq}
    /^OUTPUT_DIR=/ {$0="OUTPUT_DIR=" odq}
    {print}
  ' "$PROFILES_DIR/default.conf" > "$PROFILES_DIR/default.conf.tmp"
  mv "$PROFILES_DIR/default.conf.tmp" "$PROFILES_DIR/default.conf"
  msg "Initial setup complete.\nProfiles in ./profiles, exports in ./$outdir"
}

# ---------- Export logic ----------
build_prefix(){
  local domain="$1" user="$2" repo="$3" branch="$4"
  if [[ "$domain" == *"github.com"* ]]; then
    echo "https://raw.githubusercontent.com/$user/$repo/$branch/"
  else
    echo "https://$domain/$user/$repo/raw/branch/$branch/"
  fi
}

confirm_default_exclude(){
  dialog_cmd --yesno "By default, the following files/folders are excluded:\n\nvendor/, .gitignore, LICENSE.md, *.mo, composer*, package*, .htaccess, favicon.ico\nand image/video/audio (jpg, jpeg, png, gif, svg, bmp, webp, mp3, wav, ogg, mp4, mov, avi, mkv).\n\nKeep this exclusion?" 20 80
}

generate_export(){
  local domain="$1" user="$2" repo="$3" branch="$4" format="$5" include_pat="$6" exclude_pat="$7" keep_repo="$8" output_dir="$9" profile_name="${10}"

  mkdirp "$output_dir"
  local stamp fname header prefix files
  stamp=$(date '+%F_%H-%M-%S')
  fname="${output_dir}/${repo}_${stamp}.${format}"
  prefix=$(build_prefix "$domain" "$user" "$repo" "$branch")

  # gather files (from current cwd == repo dir)
  files="$(git ls-files)"
  [ -n "$exclude_pat" ] && files="$(printf "%s\n" "$files" | grep -Ev "$exclude_pat" || true)"
  [ -n "$include_pat" ] && files="$(printf "%s\n" "$files" | grep -E  "$include_pat"  || true)"

  header="# $APP_NAME Export
# Repository: $repo
# Domain: $domain
# Branch: $branch
# Format: $format
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Profile: ${profile_name}
# Excluded pattern: $([ -z "$exclude_pat" ] && echo 'none' || echo "$exclude_pat")
# ------------------------------------------------------------"

  case "$format" in
    txt)
      { echo "$header"; printf "%s\n" "$files" | while read -r f; do echo "${prefix}${f}"; done; } > "$fname"
      ;;
    csv)
      { echo "# $header"; echo "filename,url"; printf "%s\n" "$files" | while read -r f; do printf "\"%s\",\"%s%s\"\n" "$f" "$prefix" "$f"; done; } > "$fname"
      ;;
    json)
      { echo "$header"; echo "["; first=true
        printf "%s\n" "$files" | while read -r f; do
          url="${prefix}${f}"
          if $first; then first=false; else echo ","; fi
          printf "  {\"filename\": \"%s\", \"url\": \"%s\"}" "$f" "$url"
        done
        echo; echo "]"
      } > "$fname"
      ;;
    html)
      {
        cat <<HTML
<html><body>
<h2>File list for $repo</h2>
<pre>
$header
</pre>
<ul>
HTML
        printf "%s\n" "$files" | while read -r f; do
          printf "<li><a href='%s%s' target='_blank'>%s</a></li>\n" "$prefix" "$f" "$f"
        done
        echo "</ul></body></html>"
      } > "$fname"
      ;;
    *)
      die "Unknown format: $format"
      ;;
  esac

  echo "$fname"
}

# ---------- Repo operations ----------
clone_or_update_repo(){
  local domain="$1" user="$2" repo="$3"
  if [ ! -d "$repo/.git" ]; then
    infobox "Cloning repository..."
    git clone --quiet "https://$domain/$user/$repo.git" || return 1
  else
    dialog_cmd --yesno "Repository '$repo' already exists. Update with 'git pull'?" 8 70
    if [ $? -eq 0 ]; then
      ( cd "$repo" && git pull --quiet ) || return 1
    fi
  fi
  return 0
}

select_branch_dialog(){
  local repo="$1"
  local branches
  branches=$(cd "$repo" && git branch -r | sed 's/origin\///' | grep -v HEAD | uniq)
  if [ -z "$branches" ]; then echo "main"; return 0; fi
  local menu_items=()
  local i=1
  while IFS= read -r b; do
    menu_items+=("$i" "$b")
    i=$((i+1))
  done <<< "$branches"
  local idx
  idx=$(dialog_cmd --stdout --menu "Select branch:" 20 70 12 "${menu_items[@]}") || echo ""
  if [ -z "$idx" ]; then echo "main"; else
    echo "$branches" | awk "NR==$idx"
  fi
}

# ---------- Load profile ----------
load_profile(){
  local prof="$1"
  [ -f "$PROFILES_DIR/$prof" ] || die "Profile not found: $prof"
  # shellcheck disable=SC1090
  source "$PROFILES_DIR/$prof"
  : "${OUTPUT_DIR:?OUTPUT_DIR must be set in profile $prof}"
}

domain_token_from_tokens_conf(){
  # Map domain like github.com -> TOKEN_github_com variable
  local domain="$1" var="TOKEN_$(echo "$domain" | tr '.' '_' | tr '-' '_')"
  # shellcheck disable=SC1090
  source "$TOKENS_FILE" 2>/dev/null || true
  eval "echo \${$var-}"
}

# ---------- Repos.conf CRUD via TUI ----------
add_repo_dialog(){
  local id domain user repo branch token
  id=$(dialog_cmd --stdout --inputbox "New repository ID (e.g., mozgasnaplo):" 8 60) || return
  [ -z "$id" ] && return
  domain=$(dialog_cmd --stdout --inputbox "Domain (e.g., github.com):" 8 60 "github.com") || return
  user=$(dialog_cmd --stdout --inputbox "Username/Org:" 8 60) || return
  repo=$(dialog_cmd --stdout --inputbox "Repository name:" 8 60) || return
  branch=$(dialog_cmd --stdout --inputbox "Default branch:" 8 60 "main") || return
  token=$(dialog_cmd --stdout --inputbox "Repo-specific token (optional):" 8 60) || token=""
  {
    echo "domain=$domain"
    echo "user=$user"
    echo "repo=$repo"
    echo "default_branch=$branch"
    echo "token=$token"
  } | ini_set_section "$REPOS_FILE" "$id"
  msg "Repository '$id' saved."
}

edit_repo_dialog(){
  local id="$1"
  local kv sec
  sec=$(ini_get_section "$REPOS_FILE" "$id")
  [ -z "$sec" ] && die "Repo '$id' not found"
  local domain user repo branch token
  domain=$(echo "$sec" | awk -F= '/^domain=/{print $2}')
  user=$(  echo "$sec" | awk -F= '/^user=/{print $2}')
  repo=$(  echo "$sec" | awk -F= '/^repo=/{print $2}')
  branch=$(echo "$sec" | awk -F= '/^default_branch=/{print $2}')
  token=$( echo "$sec" | awk -F= '/^token=/{print $2}')
  domain=$(dialog_cmd --stdout --inputbox "Domain:" 8 60 "$domain") || return
  user=$(  dialog_cmd --stdout --inputbox "Username/Org:" 8 60 "$user") || return
  repo=$(  dialog_cmd --stdout --inputbox "Repository name:" 8 60 "$repo") || return
  branch=$(dialog_cmd --stdout --inputbox "Default branch:" 8 60 "$branch") || return
  token=$( dialog_cmd --stdout --inputbox "Repo token (optional):" 8 60 "$token") || token=""
  {
    echo "domain=$domain"
    echo "user=$user"
    echo "repo=$repo"
    echo "default_branch=$branch"
    echo "token=$token"
  } | ini_set_section "$REPOS_FILE" "$id"
  msg "Repository '$id' updated."
}

delete_repo_dialog(){
  local id="$1"
  yesno "Delete repository '$id' from repos.conf?" || return
  # remove section
  awk -v sec="$id" '
    BEGIN{skip=0}
    /^\[/ {
      gsub(/[\[\]]/,"",$0)
      if($0==sec){skip=1; next}
      if(skip){skip=0}
    }
    { if(!skip) print }
  ' "$REPOS_FILE" > "$REPOS_FILE.tmp.$$"
  mv "$REPOS_FILE.tmp.$$" "$REPOS_FILE"
  msg "Repository '$id' deleted."
}

choose_repo_dialog(){
  local sections s
  sections=$(list_sections "$REPOS_FILE")
  if [ -z "$sections" ]; then
    msg "No repositories defined yet. Add one first."
    echo ""
    return
  fi
  local list=() i=1
  while IFS= read -r s; do list+=("$s" "" off); i=$((i+1)); done <<< "$sections"
  local sel
  sel=$(dialog_cmd --stdout --radiolist "Select repository:" 20 70 12 "${list[@]}") || echo ""
  echo "$sel"
}

manage_repos_menu(){
  while :; do
    local choice
    choice=$(dialog_cmd --stdout --menu "Manage repositories" 15 60 6 \
      1 "Add repository" \
      2 "Edit repository" \
      3 "Delete repository" \
      4 "Back") || return
    case "$choice" in
      1) add_repo_dialog ;;
      2) id=$(choose_repo_dialog); [ -n "$id" ] && edit_repo_dialog "$id" ;;
      3) id=$(choose_repo_dialog); [ -n "$id" ] && delete_repo_dialog "$id" ;;
      4) return ;;
    esac
  done
}

# ---------- Profiles TUI ----------
choose_profile_dialog(){
  local files=()
  mapfile -t files < <(ls -1 "$PROFILES_DIR"/*.conf 2>/dev/null || true)
  local opts=()
  for f in "${files[@]}"; do
    [ -s "$f" ] && opts+=("$(basename "$f")" "" off)
  done
  [ "${#opts[@]}" -eq 0 ] && { msg "No non-empty profiles found."; echo ""; return; }
  local sel
  sel=$(dialog_cmd --stdout --radiolist "Select profile" 20 70 12 "${opts[@]}") || echo ""
  echo "$sel"
}

edit_profile_dialog(){
  local prof
  prof=$(choose_profile_dialog) || return
  [ -z "$prof" ] && return
  "$EDITOR" "$PROFILES_DIR/$prof" 2>/dev/null || nano "$PROFILES_DIR/$prof"
}

create_profile_dialog(){
  local name
  name=$(dialog_cmd --stdout --inputbox "New profile filename (e.g., myprofile.conf):" 8 60) || return
  [ -z "$name" ] && return
  cat > "$PROFILES_DIR/$name" <<'EOF'
# ------------------------------------------------------------
# Custom profile
# Purpose:
#   Predefine DOMAIN/FORMAT/OUTPUT_DIR, INCLUDE/EXCLUDE, KEEP, TOKEN.
# ------------------------------------------------------------
DOMAIN="github.com"
FORMAT="txt"
OUTPUT_DIR="exports"
INCLUDE=""
EXCLUDE=""
KEEP=false
TOKEN=""
EOF
  msg "Profile created: $name"
}

manage_profiles_menu(){
  while :; do
    local choice
    choice=$(dialog_cmd --stdout --menu "Manage profiles" 15 60 6 \
      1 "Create new profile" \
      2 "Edit existing profile" \
      3 "Back") || return
    case "$choice" in
      1) create_profile_dialog ;;
      2) edit_profile_dialog ;;
      3) return ;;
    esac
  done
}

# ---------- Exports viewer ----------
view_exports_menu(){
  mkdirp "$EXPORTS_DIR"
  local files
  mapfile -t files < <(ls -1t "$EXPORTS_DIR" 2>/dev/null || true)
  if [ "${#files[@]}" -eq 0 ]; then msg "No exports yet."; return; fi
  local opts=()
  for f in "${files[@]}"; do opts+=("$f" "" off); done
  local sel
  sel=$(dialog_cmd --stdout --radiolist "Existing exports (newest first)" 20 80 12 "${opts[@]}") || return
  [ -z "$sel" ] && return
  dialog_cmd --yesno "Open '$sel' now?" 7 60
  if [ $? -eq 0 ]; then
    textbox "$sel" "$EXPORTS_DIR/$sel"
  fi
}

# ---------- Quick Run ----------
quick_run(){
  local prof repo_id
  if [ -f "$LAST_PROFILE_FILE" ]; then prof=$(cat "$LAST_PROFILE_FILE"); else prof="default.conf"; fi
  if [ -f "$LAST_REPO_FILE" ]; then repo_id=$(cat "$LAST_REPO_FILE"); else repo_id="$(list_sections "$REPOS_FILE" | head -n1)"; fi
  [ -z "$repo_id" ] && { msg "No repositories in repos.conf. Add one first."; return; }
  run_export_flow "$prof" "$repo_id"
}

# ---------- Core flow (TUI) ----------
run_export_flow(){
  local prof="$1" repo_id="$2"

  load_profile "$prof"
  echo "$prof" > "$LAST_PROFILE_FILE"

  # repo config
  local sec domain user repo branch token
  sec=$(ini_get_section "$REPOS_FILE" "$repo_id")
  [ -z "$sec" ] && { msg "Repository '$repo_id' not found."; return; }
  domain=$(echo "$sec" | awk -F= '/^domain=/{print $2}')
  user=$(  echo "$sec" | awk -F= '/^user=/{print $2}')
  repo=$(  echo "$sec" | awk -F= '/^repo=/{print $2}')
  branch=$(echo "$sec" | awk -F= '/^default_branch=/{print $2}')
  token=$( echo "$sec" | awk -F= '/^token=/{print $2}')
  [ -z "$branch" ] && branch="main"
  echo "$repo_id" > "$LAST_REPO_FILE"

  # tokens: repo token > domain token > profile token
  local domain_token; domain_token="$(domain_token_from_tokens_conf "$domain")"
  local EFFECTIVE_TOKEN="${token:-${domain_token:-${TOKEN:-}}}"

  # clone/update
  clone_or_update_repo "$domain" "$user" "$repo" || { msg "Clone/update failed."; return; }

  # choose branch interactively
  local chosen_branch
  chosen_branch=$(select_branch_dialog "$repo")
  [ -z "$chosen_branch" ] && chosen_branch="$branch"

  # exclude confirmation
  local exclude_pat
  if [ -z "${EXCLUDE:-}" ]; then
    # Using default pattern unless user disables
    if confirm_default_exclude; then exclude_pat="$DEFAULT_EXCLUDE"; else exclude_pat=""; fi
  else
    # Custom profile EXCLUDE provided; ask to keep it
    dialog_cmd --yesno "Use profile's custom EXCLUDE regex?\n\n$EXCLUDE" 12 70
    if [ $? -eq 0 ]; then exclude_pat="$EXCLUDE"; else exclude_pat=""; fi
  fi

  # include optional refine
  local include_pat="${INCLUDE:-}"

  # move to repo and generate
  pushd "$repo" >/dev/null
  infobox "Generating export..."
  local out
  out=$(generate_export "$domain" "$user" "$repo" "$chosen_branch" "$FORMAT" "$include_pat" "$exclude_pat" "${KEEP}" "$OUTPUT_DIR" "$prof")
  popd >/dev/null

  # ask to delete cloned repo
  dialog_cmd --yesno "Export created:\n$out\n\nDelete cloned repository folder now?" 12 70
  if [ $? -eq 0 ]; then rm -rf "$repo"; fi

  msg "Done.\n$out"
}

# ---------- CLI mode ----------
CLI_MODE=false
CLI_PROFILE=""
CLI_REPO=""
CLI_BRANCH=""
CLI_FORMAT=""
CLI_KEEP=false
CLI_INCLUDE=""
CLI_EXCLUDE=""
CLI_NOEXCLUDE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --profile=*) CLI_PROFILE="${1#*=}"; CLI_MODE=true ;;
    --repo=*)    CLI_REPO="${1#*=}";    CLI_MODE=true ;;
    --branch=*)  CLI_BRANCH="${1#*=}";  CLI_MODE=true ;;
    --format=*)  CLI_FORMAT="${1#*=}";  CLI_MODE=true ;;
    --keep)      CLI_KEEP=true;         CLI_MODE=true ;;
    --include=*) CLI_INCLUDE="${1#*=}"; CLI_MODE=true ;;
    --exclude=*) CLI_EXCLUDE="${1#*=}"; CLI_MODE=true ;;
    --no-exclude) CLI_NOEXCLUDE=true;   CLI_MODE=true ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# ---------- Dependencies ----------
need git
need dialog
need jq

# ---------- First run detection ----------
if first_run; then
  prompt_initial_setup
fi

# ---------- CLI path ----------
if $CLI_MODE; then
  [ -n "$CLI_PROFILE" ] || die "CLI requires --profile=<file>"
  [ -n "$CLI_REPO" ]    || die "CLI requires --repo=<id>"
  load_profile "$CLI_PROFILE"

  # repo section
  sec=$(ini_get_section "$REPOS_FILE" "$CLI_REPO")
  [ -z "$sec" ] && die "Repo '$CLI_REPO' not found"
  domain=$(echo "$sec" | awk -F= '/^domain=/{print $2}')
  user=$(  echo "$sec" | awk -F= '/^user=/{print $2}')
  repo=$(  echo "$sec" | awk -F= '/^repo=/{print $2}')
  branch=$(echo "$sec" | awk -F= '/^default_branch=/{print $2}')
  token=$( echo "$sec" | awk -F= '/^token=/{print $2}')
  [ -n "$CLI_BRANCH" ] && branch="$CLI_BRANCH"
  [ -n "$CLI_FORMAT" ] && FORMAT="$CLI_FORMAT"
  [ "$CLI_KEEP" = true ] && KEEP=true
  [ -n "$CLI_INCLUDE" ] && INCLUDE="$CLI_INCLUDE"
  [ -n "$CLI_EXCLUDE" ] && EXCLUDE="$CLI_EXCLUDE"

  # exclusions
  exclude_pat=""
  if [ "$CLI_NOEXCLUDE" = true ]; then
    exclude_pat=""
  else
    if [ -z "${EXCLUDE:-}" ]; then exclude_pat="$DEFAULT_EXCLUDE"; else exclude_pat="$EXCLUDE"; fi
  fi
  include_pat="${INCLUDE:-}"

  # clone/update silently
  clone_or_update_repo "$domain" "$user" "$repo" || die "Clone/update failed"
  pushd "$repo" >/dev/null
  out=$(generate_export "$domain" "$user" "$repo" "$branch" "$FORMAT" "$include_pat" "$exclude_pat" "${KEEP}" "$OUTPUT_DIR" "$CLI_PROFILE")
  popd >/dev/null
  $KEEP || rm -rf "$repo"
  echo "Export: $out"
  exit 0
fi

# ---------- TUI Main Menu ----------
main_menu(){
  while :; do
    choice=$(dialog_cmd --stdout --menu "$APP_NAME - Main Menu" 18 70 8 \
      1 "Quick Run (use last/default profile & first repo)" \
      2 "Manage repositories" \
      3 "Manage profiles" \
      4 "Generate file list (select profile & repo)" \
      5 "View existing exports" \
      6 "Exit (F10/Esc)") || exit 0
    case "$choice" in
      1) quick_run ;;
      2) manage_repos_menu ;;
      3) manage_profiles_menu ;;
      4)
         prof=$(choose_profile_dialog); [ -z "$prof" ] && continue
         repo_id=$(choose_repo_dialog); [ -z "$repo_id" ] && continue
         run_export_flow "$prof" "$repo_id"
         ;;
      5) view_exports_menu ;;
      6) exit 0 ;;
    esac
  done
}

main_menu
