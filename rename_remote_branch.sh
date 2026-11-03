#!/usr/bin/env bash

set -euo pipefail

function usage() {
  printf '%s\n' \
    "Usage: $0 --repo <path> --old-branch-name <old_branch> --new-branch-name <new_branch> [--delete-old-upstream]" \
    "       $0 -r <path> -o <old_branch> -n <new_branch> [-d]" \
    "" \
    "Options:" \
    "  -r, --repo <path>                   Path to the local repository" \
    "  -o, --old-branch-name <old_name>    Old branch name" \
    "  -n, --new-branch-name <new_branch>  New branch name" \
    "  -d, --delete-old-upstream          Delete the old upstream after confirmation (off by default)" \
    "  -h, --help                          Show this help" \
    "" \
    "Environment:" \
    "  NEW_BRANCH_REGEX                  Required Bash extended regular expression" \
    "                                    Hint: Quote the regex value; use ^ and $ to match the entire branch name."
  exit "${1:-0}"
}

# log <INFO|ERR|WARN> <printf-format> [args...]; appends a newline.
function log() {
  if (($# < 2)); then
    printf '[ERR] Usage: log <INFO|ERR|WARN> <format> [args...]\n' >&2
    return 1
  fi

  local category=$1
  local format=$2
  local message
  local output_fd
  shift 2

  case "$category" in
  INFO) output_fd=1 ;;
  ERR | WARN) output_fd=2 ;;
  *)
    printf '[ERR] Unknown log category: %s\n' "$category" >&2
    return 1
    ;;
  esac

  if ! printf -v message -- "$format" "$@"; then
    printf '[ERR] Could not format log message.\n' >&2
    return 1
  fi
  printf '[%s] %s\n' "$category" "$message" >&"$output_fd"
}

# Names of things - allows you to copy/paste commands
REPO_PATH=
REMOTE=
OLD_BRANCH=
NEW_BRANCH=
DELETE_OLD_UPSTREAM=false

function parse_arguments() {
  local parsed

  if ! parsed=$(getopt -o "r:o:n:dh" \
    -l "repo:,old-branch-name:,new-branch-name:,delete-old-upstream,help" \
    -- "$@"); then
    usage 1
  fi
  eval set -- "$parsed"

  while true; do
    case "$1" in
    -r | --repo)
      REPO_PATH=$2
      shift 2
      ;;
    -o | --old-branch-name)
      OLD_BRANCH=$2
      shift 2
      ;;
    -n | --new-branch-name)
      NEW_BRANCH=$2
      shift 2
      ;;
    -d | --delete-old-upstream)
      DELETE_OLD_UPSTREAM=true
      shift
      ;;
    -h | --help)
      usage 0
      ;;
    --)
      shift
      break
      ;;
    esac
  done

  if (($# != 0)); then
    log ERR "Unexpected positional arguments: %s" "$*"
    usage 1
  fi
}

function validate_parameters() {
  local regex_status

  # Require the repository, branch names, and naming policy.
  if [[ -z "$REPO_PATH" ]]; then
    log ERR "Repository path is mandatory."
    usage 1
  fi
  if [[ -z "$OLD_BRANCH" ]]; then
    log ERR "Old branch name is mandatory."
    usage 1
  fi
  if [[ -z "$NEW_BRANCH" ]]; then
    log ERR "New branch name is mandatory."
    usage 1
  fi
  if [[ -z "${NEW_BRANCH_REGEX:-}" ]]; then
    log ERR "Environment variable NEW_BRANCH_REGEX must be set and non-empty."
    usage 1
  fi

  regex_status=0
  [[ "$NEW_BRANCH" =~ $NEW_BRANCH_REGEX ]] || regex_status=$?

  if ((regex_status == 0)); then
    log INFO "New branch name '%s' matches the required regex." "$NEW_BRANCH"
  elif ((regex_status == 2)); then
    log ERR "Invalid new branch regex '%s'." "$NEW_BRANCH_REGEX"
    usage 1
  else
    log ERR "New branch name '%s' does not match regex '%s'." "$NEW_BRANCH" "$NEW_BRANCH_REGEX"
    usage 1
  fi
}

function check_old_local_branch() {
  # Require the exact old local branch to exist.
  if ! git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$OLD_BRANCH"; then
    log ERR "Could not find local branch '%s' in repository '%s'." "$OLD_BRANCH" "$REPO_PATH"
    return 1
  else
    log INFO "Found local branch '%s' in repository '%s'." "$OLD_BRANCH" "$REPO_PATH"
  fi
}

function resolve_upstream_remote() {
  local upstream_remote
  local upstream_ref

  # Read the old local branch's upstream configuration.
  if ! upstream_remote=$(git -C "$REPO_PATH" for-each-ref --format='%(upstream:remotename)' "refs/heads/$OLD_BRANCH") ||
    ! upstream_ref=$(git -C "$REPO_PATH" for-each-ref --format='%(upstream:remoteref)' "refs/heads/$OLD_BRANCH"); then
    log ERR "Could not read upstream configuration for local branch '%s'." "$OLD_BRANCH"
    return 1
  fi

  # Require both a configured upstream remote and branch ref.
  if [[ -z "$upstream_remote" || -z "$upstream_ref" ]]; then
    log ERR "Local branch '%s' does not have a remote upstream." "$OLD_BRANCH"
    return 1
  else
    log INFO "Found configured upstream '%s' on remote '%s' for local branch '%s'." "$upstream_ref" "$upstream_remote" "$OLD_BRANCH"
  fi

  # Require the upstream branch to have the same name as the local branch.
  if [[ "$upstream_ref" != "refs/heads/$OLD_BRANCH" ]]; then
    log ERR "Local branch '%s' must track a remote branch with the same name." "$OLD_BRANCH"
    return 1
  else
    log INFO "Upstream branch name matches local branch '%s'." "$OLD_BRANCH"
  fi
  REMOTE=$upstream_remote
}

function fetch_upstream_branch() {
  # Fetch the upstream tip to confirm it exists and is accessible.
  if ! git -C "$REPO_PATH" fetch --no-tags -- "$REMOTE" "refs/heads/$OLD_BRANCH"; then
    log ERR "Could not fetch upstream '%s/%s'; verify that it exists and is accessible." "$REMOTE" "$OLD_BRANCH"
    return 1
  else
    log INFO "Fetched upstream '%s/%s'." "$REMOTE" "$OLD_BRANCH"
  fi
}

function check_upstream_commits() {
  local comparison_status

  # Ensure the local branch contains every commit from the fetched upstream.
  if git -C "$REPO_PATH" merge-base --is-ancestor FETCH_HEAD "refs/heads/$OLD_BRANCH"; then
    log INFO "Local branch '%s' contains all commits from the fetched upstream '%s/%s'." "$OLD_BRANCH" "$REMOTE" "$OLD_BRANCH"
  else
    comparison_status=$?
    # Distinguish missing upstream commits from a comparison failure.
    if ((comparison_status == 1)); then
      log ERR "Local branch '%s' does not contain all commits from upstream '%s/%s'; synchronize it before renaming." "$OLD_BRANCH" "$REMOTE" "$OLD_BRANCH"
    else
      log ERR "Could not compare local branch '%s' with upstream '%s/%s'." "$OLD_BRANCH" "$REMOTE" "$OLD_BRANCH"
    fi
    return 1
  fi
}

function check_new_remote_branch() {
  local remote_branch

  # Query the remote for the proposed branch name and detect lookup failures.
  if ! remote_branch=$(git -C "$REPO_PATH" ls-remote --heads "$REMOTE" "refs/heads/$NEW_BRANCH"); then
    log ERR "Could not check for branch '%s' on remote '%s'." "$NEW_BRANCH" "$REMOTE"
    return 1
  else
    log INFO "Checked remote '%s' for branch '%s'." "$REMOTE" "$NEW_BRANCH"
  fi

  # Reject the new name if the remote already has that branch.
  if [[ -n "$remote_branch" ]]; then
    log ERR "Branch '%s' already exists on remote '%s'." "$NEW_BRANCH" "$REMOTE"
    return 1
  else
    log INFO "Branch '%s' does not exist on remote '%s'. It can be renamed." "$NEW_BRANCH" "$REMOTE"
  fi
}

function prepare() {
  check_old_local_branch || return 1
  resolve_upstream_remote || return 1
  fetch_upstream_branch || return 1
  check_upstream_commits || return 1
  check_new_remote_branch
}

function confirm_old_upstream_deletion() {
  if [[ "$DELETE_OLD_UPSTREAM" != true ]]; then
    return 0
  fi

  local approval

  log WARN "You requested deletion of old upstream branch '%s/%s'." "$REMOTE" "$OLD_BRANCH"
  log WARN "Deleting this branch will close any open merge request whose source branch is '%s'." "$OLD_BRANCH"
  log WARN "It is YOUR responsibility to check whether a merge request exists before continuing."
  log WARN "This script performs NO merge-request checks whatsoever. It does NOT check whether any merge request exists or is open."
  log WARN "Type exactly 'YES' to approve the rename and deletion. Any other response cancels:"

  if ! IFS= read -r approval; then
    log ERR "Could not read approval; cancelled before any local rename, push, or upstream deletion."
    return 1
  fi
  if [[ "$approval" != YES ]]; then
    log WARN "Cancelled: no local rename, push, or upstream deletion was attempted."
    return 1
  fi

  log INFO "User approved continuing with deletion of '%s/%s'." "$REMOTE" "$OLD_BRANCH"
}

function rename() {
  confirm_old_upstream_deletion || return 1

  log INFO "Renaming local branch '%s' to '%s' in repository '%s'..." "$OLD_BRANCH" "$NEW_BRANCH" "$REPO_PATH"
  if git -C "$REPO_PATH" branch --move "$OLD_BRANCH" "$NEW_BRANCH"; then
    log INFO "Renamed local branch '%s' to '%s'." "$OLD_BRANCH" "$NEW_BRANCH"
  else
    log ERR "Could not rename local branch '%s' to '%s'; stopping." "$OLD_BRANCH" "$NEW_BRANCH"
    return 1
  fi

  # Prevent git from using the old name when pushing in the next step.
  # Otherwise, git will use the old upstream name instead of $NEW_BRANCH.
  log INFO "Unsetting the previous upstream for local branch '%s'..." "$NEW_BRANCH"
  if git -C "$REPO_PATH" branch --unset-upstream "$NEW_BRANCH"; then
    log INFO "Unset the previous upstream for local branch '%s'." "$NEW_BRANCH"
  else
    log ERR "Could not unset the upstream for '%s'." "$NEW_BRANCH"
    log WARN "The local rename completed, but no push was attempted."
    return 1
  fi

  log INFO "Pushing branch '%s' to remote '%s' and setting its upstream..." "$NEW_BRANCH" "$REMOTE"
  if git -C "$REPO_PATH" push --set-upstream "$REMOTE" "$NEW_BRANCH"; then
    log INFO "Pushed branch '%s' and set its upstream to '%s/%s'." "$NEW_BRANCH" "$REMOTE" "$NEW_BRANCH"
  else
    log ERR "Push/upstream setup failed for '%s/%s'." "$REMOTE" "$NEW_BRANCH"
    log WARN "The local branch was renamed and its previous upstream was unset. Inspect local and remote state before retrying."
    return 1
  fi

  if [[ "$DELETE_OLD_UPSTREAM" == true ]]; then
    log INFO "Deleting old upstream branch '%s/%s'..." "$REMOTE" "$OLD_BRANCH"
    if git -C "$REPO_PATH" push "$REMOTE" --delete "$OLD_BRANCH"; then
      log INFO "Deleted '%s/%s'." "$REMOTE" "$OLD_BRANCH"
    else
      log ERR "Could not delete old upstream branch '%s/%s'." "$REMOTE" "$OLD_BRANCH"
      log WARN "The new branch '%s/%s' has already been pushed. Inspect remote state before retrying." "$REMOTE" "$NEW_BRANCH"
      return 1
    fi
  else
    log INFO "Keeping old upstream branch '%s/%s'; use --delete-old-upstream to delete it." "$REMOTE" "$OLD_BRANCH"
  fi

  git -C "$REPO_PATH" status
}

function main() {
  parse_arguments "$@"
  validate_parameters
  prepare
  rename
}

main "$@"
