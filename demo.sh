#!/bin/bash
# Demo Navigation Script
# Usage: ./demo.sh [list|next|prev|jump <number>|discard-changes|reset|run|reload|restart|add-step <slug> <message>]

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# Optional per-project settings, see DEMO-CONTROLS.md. None of them are required.
#   DEMO_RUN_CMD        what './demo.sh run' starts
#   DEMO_AFTER_STEP     command that refreshes the app after the code changes
#   DEMO_RELOAD_SIGNAL  Flutter only: USR1 hot reload (default), USR2 hot restart
#   DEMO_MAIN_BRANCH    branch that 'reset' returns to (default: main)
if [ -f "$ROOT/demo.conf" ]; then
  . "$ROOT/demo.conf"
fi

# Written by './demo.sh run'. Git ignores it, so step changes leave it alone.
PID_FILE="$ROOT/.demo-app.pid"

# Get all step tags sorted naturally (step-01, step-02, ... step-10, etc.)
STEPS=($(git tag -l "step-*" | sort -V))

# Get current tag (if on a tagged commit)
CURRENT=$(git describe --tags --exact-match 2>/dev/null || echo "")

# Function: Bail out if this repo has no step tags yet
require_steps() {
  if [ ${#STEPS[@]} -eq 0 ]; then
    echo "❌ Error: no 'step-*' tags found in this repository"
    echo "   Demo steps must be tagged 'step-NN-slug' (e.g. step-01-counter)."
    echo "   See DEMO-CONTROLS.md for the naming convention and how to author a demo."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Refreshing the running app after a step change.
#
# Most dev servers watch the filesystem and reload themselves when the files
# change under them (Vite, Next, CRA, nodemon, dotnet watch), so for those
# projects everything below does nothing at all and nothing needs configuring.
#
# Flutter is the exception: 'flutter run' does not watch files, so it gets the
# one built-in adapter here. Copying this system to a non-Flutter project? You
# can delete the two flutter_ functions, or override them with DEMO_AFTER_STEP.
# ---------------------------------------------------------------------------

# Is this project a Flutter app? This guard also keeps the machine-wide pgrep
# below from ever signalling an app that belongs to some other repository.
is_flutter_project() {
  [ -f "$ROOT/pubspec.yaml" ] && grep -q "^[[:space:]]*flutter:" "$ROOT/pubspec.yaml" 2>/dev/null
}

# Is this pid a 'flutter run --machine' session, the way an IDE debugger starts
# one? Machine mode runs the app through the daemon and never installs the
# reload signal handlers, so signalling it KILLS the app instead of reloading
# it. Those sessions have to be left alone.
flutter_is_ide_session() {
  ps -p "$1" -o command= 2>/dev/null | grep -q -- "--machine"
}

# PID of a 'flutter run' we can safely signal, or nothing at all.
flutter_app_pid() {
  local pid="" p

  # Started by './demo.sh run'. Per 'flutter run --help' the pid file is written
  # when the signal handlers are hooked and deleted when they are removed, so
  # its presence is a guarantee that signalling this process is safe.
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi

  # Started by hand in a terminal: handlers are hooked, but there is no pid
  # file. Newest first, skipping any IDE session.
  if command -v pgrep >/dev/null 2>&1; then
    for p in $(pgrep -f "flutter_tools.snapshot run" 2>/dev/null | sort -rn); do
      if ! flutter_is_ide_session "$p"; then
        echo "$p"
        return 0
      fi
    done
  fi
}

# Is there an IDE-started session we are deliberately not touching?
flutter_ide_session_running() {
  local p
  command -v pgrep >/dev/null 2>&1 || return 1
  for p in $(pgrep -f "flutter_tools.snapshot run" 2>/dev/null); do
    flutter_is_ide_session "$p" && return 0
  done
  return 1
}

# 'flutter run --help': SIGUSR1 triggers a hot reload, SIGUSR2 a hot restart.
flutter_signal_app() {
  local sig="$1" label="$2" manual="$3" pid
  pid=$(flutter_app_pid)

  if [ -n "$pid" ]; then
    if kill -"$sig" "$pid" 2>/dev/null; then
      echo "🔥 ${label} sent to flutter run (pid ${pid})"
      # Flutter ignores a signal that arrives while an earlier reload is still
      # in flight, so stepping twice quickly would otherwise leave the app a
      # step behind. Send one more once things have settled: a redundant reload
      # costs a few hundred milliseconds and is invisible, a stale screen in
      # front of a class is not.
      ( sleep 2; kill -0 "$pid" 2>/dev/null && kill -"$sig" "$pid" 2>/dev/null ) \
        </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    else
      echo "ℹ️  Could not signal the app (pid ${pid}); press R in its terminal"
    fi
    return 0
  fi

  if flutter_ide_session_running; then
    echo "ℹ️  App started by the IDE debugger, which reloads it for you (see DEMO-CONTROLS.md)"
    if [ -n "$manual" ]; then
      echo "   An IDE runs 'flutter run --machine', which never installs the reload"
      echo "   signal handlers, so signalling it would kill the app instead of"
      echo "   reloading it. VS Code handles this itself when"
      echo "   dart.previewHotReloadOnSaveWatcher is on, which .vscode/settings.json"
      echo "   sets for this project. See DEMO-CONTROLS.md if it is not reloading."
    fi
  else
    echo "ℹ️  No running app found, so nothing to refresh (start one with './demo.sh run')"
  fi
  return 0
}

# Called after every navigation command, and by 'reload'/'restart'. Never fails,
# never blocks, and stays silent on projects that refresh themselves.
#   $1 signal to use, defaults to DEMO_RELOAD_SIGNAL then USR1
#   $2 non-empty when a human asked for this, so say something either way
notify_app() {
  local sig="${1:-${DEMO_RELOAD_SIGNAL:-USR1}}" manual="$2" label

  if [ -n "$DEMO_AFTER_STEP" ]; then
    eval "$DEMO_AFTER_STEP" || true
    return 0
  fi

  if is_flutter_project; then
    label="Hot reload"
    [ "$sig" = "USR2" ] && label="Hot restart"
    flutter_signal_app "$sig" "$label" "$manual" || true
  elif [ -n "$manual" ]; then
    echo "ℹ️  Nothing to refresh: no refresh command is configured for this project."
    echo "   Most dev servers reload themselves. If yours does not, set"
    echo "   DEMO_AFTER_STEP in demo.conf (see DEMO-CONTROLS.md)."
  fi
  return 0
}

# Function: Start the app for this project
run_app() {
  cd "$ROOT" || exit 1

  if [ -n "$DEMO_RUN_CMD" ]; then
    echo "🚀 ${DEMO_RUN_CMD} $*"
    eval "$DEMO_RUN_CMD" "$@"
    return $?
  fi

  if is_flutter_project; then
    if ! command -v flutter >/dev/null 2>&1; then
      echo "❌ Error: 'flutter' is not on your PATH"
      echo "   Install Flutter, or set DEMO_RUN_CMD in demo.conf."
      exit 1
    fi
    echo "🚀 flutter run --pid-file .demo-app.pid $*"
    flutter run --pid-file "$PID_FILE" "$@"
    return $?
  fi

  echo "ℹ️  No run command configured for this project."
  echo "   Set DEMO_RUN_CMD in demo.conf, or just start your app the usual way."
  echo "   Step changes work either way; most dev servers reload themselves."
  exit 0
}

# Function: Discard all changes
discard_changes() {
  echo "🗑️  Discarding all changes..."

  # Reset all tracked files to their last committed state
  git reset --hard HEAD 2>/dev/null

  # Remove all untracked files and directories
  git clean -fd 2>/dev/null

  echo "✅ All changes discarded"
}

# Function: Return to the demo's home branch (leaves detached HEAD)
#
# Almost always 'main'. The exception is a starter/solution repo, where 'main'
# holds the starter code WITHOUT this tooling and the demo lives on a branch of
# its own: checking out 'main' there would delete demo.sh and the buttons from
# under you mid-lecture. Those repos set DEMO_MAIN_BRANCH in demo.conf.
reset_to_main() {
  # Discard any changes before switching
  discard_changes

  local branch="${DEMO_MAIN_BRANCH:-main}"

  git checkout "$branch" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "🏁 Back on the ${branch} branch"
  else
    echo "❌ Error: Could not checkout ${branch}"
    exit 1
  fi
}

# Function: List all available steps
list_steps() {
  require_steps

  echo "📚 Available Demo Steps:"
  echo "======================="

  for i in "${!STEPS[@]}"; do
    STEP="${STEPS[$i]}"
    # Get commit message for this tag
    MESSAGE=$(git log -1 --pretty=%B "${STEP}" | head -n 1)

    # Mark current step
    if [[ "${STEP}" = "${CURRENT}" ]]; then
      echo "👉 $((i + 1)). ${STEP} - ${MESSAGE}"
    else
      echo "   $((i + 1)). ${STEP} - ${MESSAGE}"
    fi
  done

  echo ""
  echo "Total: ${#STEPS[@]} steps"

  if [[ -n "${CURRENT}" ]]; then
    echo "Current: ${CURRENT}"
  else
    echo "Current: Not on a step tag"
  fi
}

# Function: Move to next step
next_step() {
  require_steps

  # Discard any changes before switching
  discard_changes

  # Find current step index
  CURRENT_INDEX=-1
  for i in "${!STEPS[@]}"; do
    if [[ "${STEPS[$i]}" = "${CURRENT}" ]]; then
      CURRENT_INDEX=$i
      break
    fi
  done

  # If not on a tagged commit, start from the beginning
  if [ $CURRENT_INDEX -eq -1 ]; then
    echo "📍 Not on a step tag. Starting from ${STEPS[0]}..."
    git checkout "${STEPS[0]}" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "✅ Moved to ${STEPS[0]}"
    else
      echo "❌ Error: Could not checkout ${STEPS[0]}"
    fi
    exit 0
  fi

  # Go to next step
  NEXT_INDEX=$((CURRENT_INDEX + 1))
  if [ $NEXT_INDEX -lt ${#STEPS[@]} ]; then
    git checkout "${STEPS[$NEXT_INDEX]}" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "✅ Moved to ${STEPS[$NEXT_INDEX]} ($(($NEXT_INDEX + 1))/${#STEPS[@]})"
    else
      echo "❌ Error: Could not checkout ${STEPS[$NEXT_INDEX]}"
    fi
  else
    echo "🏁 Already at the last step: ${CURRENT}"
    echo "   Run './demo.sh reset' to return to main branch"
  fi
}

# Function: Move to previous step
prev_step() {
  require_steps

  # Discard any changes before switching
  discard_changes

  # Find current step index
  CURRENT_INDEX=-1
  for i in "${!STEPS[@]}"; do
    if [[ "${STEPS[$i]}" = "${CURRENT}" ]]; then
      CURRENT_INDEX=$i
      break
    fi
  done

  # If not on a tagged commit, warn user
  if [ $CURRENT_INDEX -eq -1 ]; then
    echo "📍 Not on a step tag. Use './demo.sh list' to see available steps."
    exit 1
  fi

  # Go to previous step
  PREV_INDEX=$((CURRENT_INDEX - 1))
  if [ $PREV_INDEX -ge 0 ]; then
    git checkout "${STEPS[$PREV_INDEX]}" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "✅ Moved to ${STEPS[$PREV_INDEX]} ($(($PREV_INDEX + 1))/${#STEPS[@]})"
    else
      echo "❌ Error: Could not checkout ${STEPS[$PREV_INDEX]}"
    fi
  else
    echo "🎬 Already at the first step: ${CURRENT}"
  fi
}

# Function: Jump to a specific step number
jump_to_step() {
  require_steps

  STEP_NUM=$1

  if [[ -z "$STEP_NUM" ]]; then
    echo "❌ Error: Please provide a step number"
    echo "Usage: ./demo.sh jump <number>"
    exit 1
  fi

  # Discard any changes before switching
  discard_changes

  # Find the step matching step-{number}*
  TARGET_STEP=""
  for STEP in "${STEPS[@]}"; do
    if [[ "$STEP" == "step-${STEP_NUM}" ]] || [[ "$STEP" == step-${STEP_NUM}-* ]]; then
      TARGET_STEP="$STEP"
      break
    fi
  done

  if [[ -z "$TARGET_STEP" ]]; then
    echo "❌ Error: Step ${STEP_NUM} not found"
    echo "Run './demo.sh list' to see available steps"
    exit 1
  fi

  # Checkout the target step
  git checkout "$TARGET_STEP" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "✅ Jumped to ${TARGET_STEP}"
  else
    echo "❌ Error: Could not checkout ${TARGET_STEP}"
    exit 1
  fi
}

# Function: Commit the current work as the next demo step
add_step() {
  SLUG=$1
  MESSAGE=$2

  if [[ -z "$SLUG" ]] || [[ -z "$MESSAGE" ]]; then
    echo "❌ Error: Please provide a slug and a commit message"
    echo "Usage: ./demo.sh add-step <slug> \"<commit message>\""
    echo "Example: ./demo.sh add-step model \"Add the KaiEvent model\""
    exit 1
  fi

  # The slug becomes part of a tag name, so keep it simple and predictable
  if ! [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "❌ Error: Invalid slug '${SLUG}'"
    echo "   Use lowercase letters, digits and hyphens only (e.g. 'favourite-button')"
    exit 1
  fi

  # A commit made on a detached HEAD is destroyed by the next step change
  if ! git symbolic-ref -q HEAD >/dev/null; then
    echo "❌ Error: You are on a step tag (detached HEAD), not a branch"
    echo "   Run './demo.sh reset' to get back to main, then try again."
    exit 1
  fi

  # Work from the repo root so that 'git add' covers the whole project
  ROOT=$(git rev-parse --show-toplevel)
  cd "$ROOT" || exit 1

  if [[ -z "$(git status --porcelain)" ]]; then
    echo "❌ Error: Nothing to commit, the working tree is clean"
    echo "   Make the changes for this step first, then run add-step."
    exit 1
  fi

  # Next number is the highest existing one plus one, so gaps never collide
  MAX=0
  for STEP in $(git tag -l "step-*"); do
    NUM=$(echo "$STEP" | sed -n 's/^step-0*\([0-9][0-9]*\).*$/\1/p')
    if [[ -n "$NUM" ]] && [ "$NUM" -gt "$MAX" ]; then
      MAX=$NUM
    fi
  done
  NEXT=$(printf "%02d" $((MAX + 1)))
  TAG="step-${NEXT}-${SLUG}"

  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "❌ Error: Tag ${TAG} already exists"
    exit 1
  fi

  git add -A
  if [ $? -ne 0 ]; then
    echo "❌ Error: Could not stage changes, nothing committed"
    exit 1
  fi

  git commit -q -m "$MESSAGE"
  if [ $? -ne 0 ]; then
    echo "❌ Error: Commit failed, no tag created"
    exit 1
  fi

  git tag "$TAG"
  if [ $? -ne 0 ]; then
    echo "❌ Error: Committed, but tagging failed"
    echo "   Tag it yourself with: git tag ${TAG}"
    exit 1
  fi

  echo "✅ Added ${TAG} ($(git rev-parse --short HEAD))"
  echo "   ${MESSAGE}"
  echo "   Remember to add this step to the table in README.md"
}

# Function: Put the current changes into every step at once
#
# For things every step should carry: the README, the demo tooling, a licence.
# It commits your changes, rebuilds that commit onto the one before step 1, and
# replays every step on top, so all of them end up with it. History is rewritten
# and the step tags are moved, which is fine for a local example repo and is the
# only way a file can be identical at every checkpoint.
update_all() {
  MESSAGE=$1

  if [[ -z "$MESSAGE" ]]; then
    echo "❌ Error: Please provide a commit message"
    echo "Usage: ./demo.sh update-all \"<commit message>\""
    echo "Example: ./demo.sh update-all \"Add the step table to the README\""
    exit 1
  fi

  require_steps

  # Same rule as add-step: from a detached HEAD there is no branch to rewrite
  BRANCH=$(git symbolic-ref -q --short HEAD)
  if [[ -z "$BRANCH" ]]; then
    echo "❌ Error: You are on a step tag (detached HEAD), not a branch"
    echo "   Run './demo.sh reset' to get back to main, then try again."
    exit 1
  fi

  cd "$ROOT" || exit 1

  if [[ -z "$(git status --porcelain)" ]]; then
    echo "❌ Error: Nothing to commit, the working tree is clean"
    echo "   Make the change you want every step to have, then run update-all."
    exit 1
  fi

  # Every step has to be on this branch, or the replay below would drop one
  for STEP in "${STEPS[@]}"; do
    if ! git merge-base --is-ancestor "$STEP" HEAD 2>/dev/null; then
      echo "❌ Error: ${STEP} is not on '${BRANCH}'"
      echo "   update-all rewrites the steps of the current branch. Nothing has changed."
      exit 1
    fi
  done

  FIRST="${STEPS[0]}"
  BASE=$(git rev-parse -q --verify "${FIRST}^" 2>/dev/null)
  if [[ -z "$BASE" ]]; then
    echo "❌ Error: ${FIRST} is the very first commit in this repository"
    echo "   update-all needs a commit before it to build on. Nothing has changed."
    exit 1
  fi

  ORIG=$(git rev-parse HEAD)

  git add -A
  if ! git commit -q -m "$MESSAGE"; then
    echo "❌ Error: Commit failed, nothing has changed"
    exit 1
  fi

  # Everything from here on is recoverable with: git reset --hard demo-backup
  git tag -f demo-backup "$BRANCH" >/dev/null

  # Apply the same change to the commit before step 1. Whole files, not a diff,
  # so it does not matter that the surrounding steps look different there.
  TMP="demo-update-all-$$"
  git checkout -q -B "$TMP" "$BASE"
  while IFS=$'\t' read -r STATUS FILE; do
    case "$STATUS" in
      D) git rm -q --ignore-unmatch -- "$FILE" >/dev/null 2>&1 ;;
      *) git checkout "$BRANCH" -- "$FILE" ;;
    esac
  done < <(git diff --name-status --no-renames "$ORIG" "$BRANCH")
  git commit -q --allow-empty -m "$MESSAGE"

  # Replay the steps themselves on top of it
  if ! git rebase --onto "$TMP" "$BASE" "$ORIG" >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    git checkout -q -B "$BRANCH" demo-backup
    git branch -q -D "$TMP" >/dev/null 2>&1
    echo "❌ Error: the steps did not replay cleanly on top of that change"
    echo "   Nothing has moved: '${BRANCH}' and every tag are as they were, with"
    echo "   your change committed on top. This usually means the change touches"
    echo "   a file that the steps themselves change."
    exit 1
  fi
  git checkout -q -B "$BRANCH"

  # Check the replay before trusting it with the tags
  NEW=($(git rev-list --reverse "${TMP}..${BRANCH}"))
  FAILURE=""
  if [ ${#NEW[@]} -ne ${#STEPS[@]} ]; then
    FAILURE="expected ${#STEPS[@]} steps after the replay, found ${#NEW[@]}"
  else
    for i in "${!STEPS[@]}"; do
      if [[ "$(git log -1 --pretty=%s "${STEPS[$i]}")" != "$(git log -1 --pretty=%s "${NEW[$i]}")" ]]; then
        FAILURE="step $((i + 1)) came back in the wrong order"
        break
      fi
    done
  fi
  if [[ -n "$FAILURE" ]]; then
    git checkout -q -B "$BRANCH" demo-backup
    git branch -q -D "$TMP" >/dev/null 2>&1
    echo "❌ Error: ${FAILURE}"
    echo "   The tags were not moved and '${BRANCH}' is back as it was."
    exit 1
  fi

  for i in "${!STEPS[@]}"; do
    git tag -f "${STEPS[$i]}" "${NEW[$i]}" >/dev/null
  done
  git branch -q -D "$TMP" >/dev/null 2>&1

  echo "✅ ${MESSAGE}"
  echo "   Now in all ${#STEPS[@]} steps, ${STEPS[0]} to ${STEPS[${#STEPS[@]} - 1]}"
  echo "   Undo with: git reset --hard demo-backup   (then re-tag the steps)"
}

# Main script logic
COMMAND=$1

# Anything that changes the working tree refreshes the app on the way out.
# An EXIT trap catches every path through the functions below, including the
# ones that bail out early, so a refresh can never be skipped or doubled up.
on_exit() {
  local rc=$?
  notify_app
  exit $rc
}

case "$COMMAND" in
  next|prev|jump|reset|main|discard-changes)
    trap on_exit EXIT
    ;;
esac

case "$COMMAND" in
  list)
    list_steps
    ;;
  next)
    next_step
    ;;
  prev)
    prev_step
    ;;
  jump)
    jump_to_step "$2"
    ;;
  discard-changes)
    discard_changes
    ;;
  reset|main)
    reset_to_main
    ;;
  run)
    shift
    run_app "$@"
    ;;
  reload)
    notify_app USR1 manual
    ;;
  restart)
    notify_app USR2 manual
    ;;
  add-step)
    add_step "$2" "$3"
    ;;
  update-all)
    update_all "$2"
    ;;
  *)
    echo "Usage: ./demo.sh [list|next|prev|jump <number>|discard-changes|reset|run|reload|restart|add-step <slug> <message>]"
    echo ""
    echo "Commands:"
    echo "  list            - Show all available demo steps"
    echo "  next            - Move to the next step"
    echo "  prev            - Move to the previous step"
    echo "  jump <number>   - Jump to a specific step (e.g., './demo.sh jump 23')"
    echo "  discard-changes - Discard all changes (modifications, additions, deletions)"
    echo "  reset           - Leave the demo and return to the main branch"
    echo ""
    echo "Running the app:"
    echo "  run [args...]   - Start the app (Flutter projects need no setup)"
    echo "  reload          - Refresh the running app by hand (Flutter: hot reload)"
    echo "  restart         - Restart the running app by hand (Flutter: hot restart)"
    echo ""
    echo "Authoring:"
    echo "  add-step <slug> <message> - Commit the current work as the next step and tag it"
    echo "                              Example: ./demo.sh add-step model \"Add the KaiEvent model\""
    echo "  update-all <message>      - Commit the current work into EVERY step (README, tooling)"
    echo "                              Example: ./demo.sh update-all \"Fix a typo in the README\""
    exit 1
    ;;
esac
