#!/usr/bin/env bash
#
# cherry-pick-hotfix.sh
#
# Generic helper to take commits that exist on a SOURCE branch but not on a
# TARGET branch, show them for review, and cherry-pick them onto TARGET after
# explicit confirmation. Also supports undoing a hotfix batch later, either
# safely (revert) or as a hard clean-slate reset. Meant to live inside the
# repo (e.g. scripts/) so anyone can run it whenever a hotfix needs to go
# from a feature/dev branch onto main/prod/release, confidently.
#
# Usage:
#   Apply a hotfix batch:
#     ./cherry-pick-hotfix.sh <source-branch> <target-branch> [options]
#
#   List recorded hotfix runs for a branch:
#     ./cherry-pick-hotfix.sh --list-runs <target-branch>
#
#   Safely undo a run (adds new revert commits, keeps history):
#     ./cherry-pick-hotfix.sh --revert <target-branch> [--run N] [-y]
#
#   Hard reset a branch back to its state before a run (rewrites history):
#     ./cherry-pick-hotfix.sh --reset-clean <target-branch> [--run N] [-y]
#
# Apply options:
#   -y, --yes           Skip the batch confirmation prompt (still shows the list)
#   -i, --interactive   Confirm each commit individually (y/n/s=skip/q=quit)
#   -n, --dry-run       Show what would be cherry-picked, apply nothing
#   --no-fetch          Don't run 'git fetch' before comparing branches
#   --push              After a successful run, offer to push target to origin
#
# Undo options:
#   --run N             Pick the Nth most recent run (1 = latest, default 1)
#   -y, --yes           Skip confirmation
#
#   -h, --help          Show this help
#
# Behaviour notes:
#   - Only non-merge commits reachable from SOURCE but not TARGET are considered
#     (git log target..source --no-merges), so commits target already has
#     are never re-applied.
#   - Commits already cherry-picked onto target in an earlier run of this
#     script are detected (via the "(cherry picked from commit <sha>)" note
#     that -x adds) and skipped automatically. Safe to re-run after resolving
#     a conflict manually.
#   - On a cherry-pick conflict, the script stops and leaves the repo in the
#     standard git conflict state. Resolve it the normal way
#     (git add ... && git cherry-pick --continue, or --abort), then re-run
#     this script to pick up the remaining commits.
#   - Every successful apply run is recorded locally under
#     .git/cherry-pick-hotfix/<target>/ - a timestamped log of which commits
#     were applied, plus a tag marking target's tip *before* the run. This is
#     what --revert and --reset-clean use, and it is local-only (never pushed,
#     never committed to the repo).
#   - --revert creates new commits that undo the batch - safe for shared/prod
#     branches, preserves history. Prefer this.
#   - --reset-clean hard-resets target back to the pre-run tag - rewrites
#     history. Only use on branches nobody else has pulled, or be ready to
#     force-push with --force-with-lease afterwards.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '[INFO]  %s\n' "$*"; }
warn()  { printf '[WARN]  %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

confirm() {
  # confirm "prompt text" -> 0 if user answered yes
  local prompt="$1" reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
MODE="apply"           # apply | list-runs | revert | reset-clean
SOURCE=""
TARGET=""
ASSUME_YES=false
INTERACTIVE=false
DRY_RUN=false
NO_FETCH=false
DO_PUSH=false
RUN_N=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-runs) MODE="list-runs"; shift ;;
    --revert) MODE="revert"; shift ;;
    --reset-clean) MODE="reset-clean"; shift ;;
    --run) RUN_N="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -i|--interactive) INTERACTIVE=true; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    --no-fetch) NO_FETCH=true; shift ;;
    --push) DO_PUSH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      die "Unknown option: $1 (use -h for help)"
      ;;
    *)
      if [[ "$MODE" == "apply" ]]; then
        if [[ -z "$SOURCE" ]]; then
          SOURCE="$1"
        elif [[ -z "$TARGET" ]]; then
          TARGET="$1"
        else
          die "Unexpected argument: $1 (use -h for help)"
        fi
      else
        if [[ -z "$TARGET" ]]; then
          TARGET="$1"
        else
          die "Unexpected argument: $1 (use -h for help)"
        fi
      fi
      shift
      ;;
  esac
done

if [[ "$MODE" == "apply" ]]; then
  [[ -n "$SOURCE" && -n "$TARGET" ]] || { usage; die "source and target branches are required"; }
  [[ "$SOURCE" != "$TARGET" ]] || die "source and target branch are the same ($SOURCE)"
else
  [[ -n "$TARGET" ]] || { usage; die "a target branch is required for --$MODE"; }
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository."

if [[ -n "$(git status --porcelain)" ]]; then
  die "Working tree is not clean. Commit, stash, or discard changes before running this script."
fi

resolve_branch_ref() {
  # Prefer local branch; fall back to origin/<branch> if only the remote exists.
  local branch="$1"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    echo "origin/$branch"
  else
    die "Branch '$branch' not found locally or as origin/$branch"
  fi
}

GIT_DIR="$(git rev-parse --git-dir)"
STATE_ROOT="$GIT_DIR/cherry-pick-hotfix"

# ---------------------------------------------------------------------------
# Shared: locate a run log for TARGET (Nth most recent, 1 = latest)
# ---------------------------------------------------------------------------
find_run_file() {
  local target="$1" n="$2"
  local dir="$STATE_ROOT/$target"
  [[ -d "$dir" ]] || die "No recorded runs for '$target'."
  local file
  file="$(ls -1t "$dir" 2>/dev/null | sed -n "${n}p")"
  [[ -n "$file" ]] || die "No run #$n found for '$target'. Use --list-runs to see what's recorded."
  echo "$dir/$file"
}

# ---------------------------------------------------------------------------
# MODE: list-runs
# ---------------------------------------------------------------------------
if [[ "$MODE" == "list-runs" ]]; then
  dir="$STATE_ROOT/$TARGET"
  if [[ ! -d "$dir" ]]; then
    info "No recorded runs for '$TARGET'."
    exit 0
  fi
  i=1
  for f in $(ls -1t "$dir"); do
    src="$(grep '^source=' "$dir/$f" | cut -d= -f2-)"
    tag="$(grep '^pretag=' "$dir/$f" | cut -d= -f2-)"
    count="$(grep -c '^sha=' "$dir/$f" || true)"
    ts="${f%.log}"
    printf '%d) %s   source=%-20s commits=%-3s pretag=%s\n' "$i" "$ts" "$src" "$count" "$tag"
    i=$((i+1))
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: revert (safe - adds new commits that undo the batch)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "revert" ]]; then
  RUN_FILE="$(find_run_file "$TARGET" "$RUN_N")"
  SRC="$(grep '^source=' "$RUN_FILE" | cut -d= -f2-)"
  PRETAG="$(grep '^pretag=' "$RUN_FILE" | cut -d= -f2-)"
  mapfile -t RUN_SHAS < <(grep '^sha=' "$RUN_FILE" | cut -d= -f2-)

  [[ ${#RUN_SHAS[@]} -gt 0 ]] || die "Run file '$RUN_FILE' has no recorded commits."

  info "Reverting run: $(basename "$RUN_FILE")  (source=$SRC, ${#RUN_SHAS[@]} commit(s), pre-run tag=$PRETAG)"

  # Reverse chronological order: undo most-recent-first.
  REVERSED=()
  for ((idx=${#RUN_SHAS[@]}-1; idx>=0; idx--)); do
    sha="${RUN_SHAS[idx]}"
    if git log "$TARGET" --grep="This reverts commit $sha" --oneline | grep -q .; then
      continue  # already reverted in an earlier run
    fi
    REVERSED+=("$sha")
  done

  if [[ ${#REVERSED[@]} -eq 0 ]]; then
    info "Every commit in this run has already been reverted. Nothing to do."
    exit 0
  fi

  echo
  info "Commits that will be reverted on '$TARGET' (most recent first):"
  echo
  for sha in "${REVERSED[@]}"; do
    git log -1 --pretty=format:'  %h  %ad  %an  %s' --date=short "$sha" 2>/dev/null || echo "  $sha (no longer in history)"
    echo
  done
  echo

  if [[ "$ASSUME_YES" == false ]]; then
    confirm "Revert these ${#REVERSED[@]} commit(s) on '$TARGET'?" \
      || { info "Aborted by user. No changes made."; exit 0; }
  fi

  git checkout --quiet "$TARGET"

  for sha in "${REVERSED[@]}"; do
    info "Reverting $(git log -1 --pretty=format:'%h %s' "$sha")"
    if ! git revert --no-edit "$sha"; then
      error "Conflict while reverting $sha"
      error "Resolve it, then run:"
      error "    git add <files> && git revert --continue"
      error "  (or 'git revert --abort' to bail out)"
      error "Re-run '--revert $TARGET' afterwards - already-reverted commits are skipped automatically."
      exit 1
    fi
  done

  echo
  info "Done. ${#REVERSED[@]} commit(s) reverted on '$TARGET'."
  info "(This added new commits; '$TARGET' history is preserved. Push when ready.)"
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: reset-clean (destructive - hard reset to pre-run state)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "reset-clean" ]]; then
  RUN_FILE="$(find_run_file "$TARGET" "$RUN_N")"
  SRC="$(grep '^source=' "$RUN_FILE" | cut -d= -f2-)"
  PRETAG="$(grep '^pretag=' "$RUN_FILE" | cut -d= -f2-)"

  git rev-parse --verify --quiet "$PRETAG" >/dev/null \
    || die "Pre-run tag '$PRETAG' no longer exists - cannot reset-clean this run. Use --revert instead."

  warn "This will HARD RESET '$TARGET' to '$PRETAG', discarding any commits made on"
  warn "'$TARGET' after that point - including the hotfix batch from '$SRC' AND anything"
  warn "else committed to '$TARGET' since then. This rewrites history."
  warn "If '$TARGET' has already been pushed, you will need to force-push"
  warn "(git push --force-with-lease) afterwards, and anyone who pulled will need to reset too."
  echo
  git log --oneline "${PRETAG}..${TARGET}" 2>/dev/null | sed 's/^/  would discard: /'
  echo

  if [[ "$ASSUME_YES" == false ]]; then
    confirm "Type y to confirm HARD RESET of '$TARGET' to '$PRETAG'" \
      || { info "Aborted by user. No changes made."; exit 0; }
  fi

  git checkout --quiet "$TARGET"
  git reset --hard "$PRETAG"

  echo
  info "Done. '$TARGET' has been hard-reset to '$PRETAG' (state before this run)."
  info "If this branch is shared/pushed: git push --force-with-lease origin $TARGET"
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: apply (default)
# ---------------------------------------------------------------------------
if [[ "$NO_FETCH" == false ]]; then
  info "Fetching latest refs..."
  git fetch --quiet --all --prune
fi

SOURCE_REF="$(resolve_branch_ref "$SOURCE")"
TARGET_REF="$(resolve_branch_ref "$TARGET")"

info "Source: $SOURCE  (ref: $SOURCE_REF)"
info "Target: $TARGET  (ref: $TARGET_REF)"

ALL_CANDIDATES=$(git log "${TARGET_REF}..${SOURCE_REF}" --no-merges --reverse --pretty=%H)

if [[ -z "$ALL_CANDIDATES" ]]; then
  info "No commits found on '$SOURCE' that are missing from '$TARGET'. Nothing to do."
  exit 0
fi

# Filter out commits already cherry-picked onto target in a previous run
# (detected via the "(cherry picked from commit <sha>)" trailer that -x adds).
TO_APPLY=()
ALREADY_APPLIED=()
for sha in $ALL_CANDIDATES; do
  if git log "$TARGET_REF" --grep="cherry picked from commit $sha" --oneline | grep -q .; then
    ALREADY_APPLIED+=("$sha")
  else
    TO_APPLY+=("$sha")
  fi
done

if [[ ${#ALREADY_APPLIED[@]} -gt 0 ]]; then
  info "${#ALREADY_APPLIED[@]} commit(s) already cherry-picked onto '$TARGET' previously - skipping those."
fi

if [[ ${#TO_APPLY[@]} -eq 0 ]]; then
  info "Everything from '$SOURCE' has already been applied to '$TARGET'. Nothing to do."
  exit 0
fi

echo
info "Commits to cherry-pick from '$SOURCE' onto '$TARGET' (oldest first):"
echo
for sha in "${TO_APPLY[@]}"; do
  git log -1 --pretty=format:'  %C(yellow)%h%Creset  %ad  %C(cyan)%an%Creset  %s' --date=short "$sha"
  echo
done
echo

if [[ "$DRY_RUN" == true ]]; then
  info "Dry run - no changes made. ${#TO_APPLY[@]} commit(s) would be cherry-picked."
  exit 0
fi

if [[ "$INTERACTIVE" == false && "$ASSUME_YES" == false ]]; then
  confirm "Cherry-pick these ${#TO_APPLY[@]} commit(s) from '$SOURCE' onto '$TARGET'?" \
    || { info "Aborted by user. No changes made."; exit 0; }
fi

info "Checking out '$TARGET'..."
if git show-ref --verify --quiet "refs/heads/$TARGET"; then
  git checkout --quiet "$TARGET"
else
  git checkout --quiet -b "$TARGET" "$TARGET_REF"
fi

# Record a pre-run tag + run log so this batch can be undone later.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
PRETAG="pre-hotfix/${TARGET}/${TS}"
git tag -a "$PRETAG" -m "State of $TARGET before cherry-picking from $SOURCE" HEAD

STATE_DIR="$STATE_ROOT/$TARGET"
mkdir -p "$STATE_DIR"
RUN_FILE="$STATE_DIR/${TS}.log"
{
  echo "source=$SOURCE"
  echo "pretag=$PRETAG"
} > "$RUN_FILE"

APPLIED=()
SKIPPED=()

for sha in "${TO_APPLY[@]}"; do
  subject="$(git log -1 --pretty=format:'%h %s' "$sha")"

  if [[ "$INTERACTIVE" == true ]]; then
    read -r -p "Apply commit $subject ? [y/n/s(kip)/q(uit)] " choice
    case "$choice" in
      [Yy]) : ;;
      [Ss]) info "Skipping $subject"; SKIPPED+=("$sha"); continue ;;
      [Qq]) info "Stopping at user request. ${#APPLIED[@]} commit(s) applied so far."; break ;;
      *) info "Skipping $subject (no confirmation)"; SKIPPED+=("$sha"); continue ;;
    esac
  fi

  info "Cherry-picking $subject"
  if ! git cherry-pick -x "$sha"; then
    error "Conflict while cherry-picking $subject"
    error "Resolve it, then run:"
    error "    git add <files> && git cherry-pick --continue"
    error "  (or 'git cherry-pick --abort' to bail out)"
    error "Re-run this script afterwards - already-applied commits are detected and skipped automatically."
    exit 1
  fi
  NEW_SHA="$(git rev-parse HEAD)"
  echo "sha=$NEW_SHA" >> "$RUN_FILE"
  APPLIED+=("$sha")
done

echo
info "Done. ${#APPLIED[@]} commit(s) applied, ${#SKIPPED[@]} skipped."
if [[ ${#APPLIED[@]} -gt 0 ]]; then
  echo
  git log --oneline -n "${#APPLIED[@]}"
  echo
  info "Recorded as a run you can undo later:"
  info "  Safe undo (adds revert commits):  ./$( basename "$0") --revert $TARGET"
  info "  Hard reset (rewrites history):    ./$( basename "$0") --reset-clean $TARGET"
fi

if [[ "$DO_PUSH" == true && ${#APPLIED[@]} -gt 0 ]]; then
  if confirm "Push '$TARGET' to origin now?"; then
    git push origin "$TARGET"
  else
    info "Skipped push. Remember to push '$TARGET' manually when ready."
  fi
fi
