#!/usr/bin/env bash
#
# cherry-pick-hotfix.sh
#
# Generic helper to take commits that exist on a SOURCE branch but not on a
# TARGET branch, show them for review, and cherry-pick them onto TARGET after
# explicit confirmation. Meant to live inside the repo (e.g. scripts/) so
# anyone can run it whenever a hotfix needs to go from a feature/dev branch
# onto main/prod/release without guessing git commands under pressure.
#
# Usage:
#   ./cherry-pick-hotfix.sh <source-branch> <target-branch> [options]
#
# Options:
#   -y, --yes           Skip the batch confirmation prompt (still shows the list)
#   -i, --interactive   Confirm each commit individually (y/n/s=skip/q=quit)
#   -n, --dry-run       Show what would be cherry-picked, apply nothing
#   --no-fetch          Don't run 'git fetch' before comparing branches
#   --push              After a successful run, offer to push target to origin
#   -h, --help          Show this help
#
# Behaviour notes:
#   - Only non-merge commits reachable from SOURCE but not TARGET are considered
#     (git log target..source --no-merges), so commits target already has
#     (e.g. from a prior merge) are never re-applied.
#   - Commits already cherry-picked onto target in an earlier run of this
#     script are detected (via the "(cherry picked from commit <sha>)" note
#     that -x adds) and skipped automatically. This makes the script safe to
#     re-run after resolving a conflict manually.
#   - On a cherry-pick conflict, the script stops and leaves the repo in the
#     standard git conflict state. Resolve it the normal way
#     (git add ... && git cherry-pick --continue, or --abort), then re-run
#     this script to pick up the remaining commits.
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
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
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
SOURCE=""
TARGET=""
ASSUME_YES=false
INTERACTIVE=false
DRY_RUN=false
NO_FETCH=false
DO_PUSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
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
      if [[ -z "$SOURCE" ]]; then
        SOURCE="$1"
      elif [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        die "Unexpected argument: $1 (use -h for help)"
      fi
      shift
      ;;
  esac
done

[[ -n "$SOURCE" && -n "$TARGET" ]] || { usage; die "source and target branches are required"; }
[[ "$SOURCE" != "$TARGET" ]] || die "source and target branch are the same ($SOURCE)"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository."

if [[ -n "$(git status --porcelain)" ]]; then
  die "Working tree is not clean. Commit, stash, or discard changes before running this script."
fi

if [[ "$NO_FETCH" == false ]]; then
  info "Fetching latest refs..."
  git fetch --quiet --all --prune
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

SOURCE_REF="$(resolve_branch_ref "$SOURCE")"
TARGET_REF="$(resolve_branch_ref "$TARGET")"

info "Source: $SOURCE  (ref: $SOURCE_REF)"
info "Target: $TARGET  (ref: $TARGET_REF)"

# ---------------------------------------------------------------------------
# Build the candidate commit list
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "$INTERACTIVE" == false && "$ASSUME_YES" == false ]]; then
  confirm "Cherry-pick these ${#TO_APPLY[@]} commit(s) from '$SOURCE' onto '$TARGET'?" \
    || { info "Aborted by user. No changes made."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Checkout target and apply
# ---------------------------------------------------------------------------
info "Checking out '$TARGET'..."
if git show-ref --verify --quiet "refs/heads/$TARGET"; then
  git checkout --quiet "$TARGET"
else
  git checkout --quiet -b "$TARGET" "$TARGET_REF"
fi

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
  APPLIED+=("$sha")
done

echo
info "Done. ${#APPLIED[@]} commit(s) applied, ${#SKIPPED[@]} skipped."
if [[ ${#APPLIED[@]} -gt 0 ]]; then
  echo
  git log --oneline -n "${#APPLIED[@]}"
fi

# ---------------------------------------------------------------------------
# Optional push
# ---------------------------------------------------------------------------
if [[ "$DO_PUSH" == true && ${#APPLIED[@]} -gt 0 ]]; then
  if confirm "Push '$TARGET' to origin now?"; then
    git push origin "$TARGET"
  else
    info "Skipped push. Remember to push '$TARGET' manually when ready."
  fi
fi
