#!/usr/bin/env bash
# Rebuild a downstream integration branch on top of upstream and replay
# commits from a source branch since a sync tag.
#
# Typical flow:
#   1. Fetch upstream
#   2. Create/reset <target-branch> to upstream/<upstream-branch> (or --upstream-tag)
#   3. Cherry-pick commits from <since-tag>..<source-branch> (oldest first)
#
# Example:
#   dev/tools/prepare-branch-rebase.sh --since-tag v0.4.6
#   dev/tools/prepare-branch-rebase.sh --since-tag v0.4.6 --upstream-tag v0.5.0 -i

set -euo pipefail

# Avoid git log opening less during scripted output.
export GIT_PAGER=cat

SOURCE_BRANCH="main"
TARGET_BRANCH="next"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
UPSTREAM_TAG=""
SINCE_TAG=""
INTERACTIVE=false
DRY_RUN=false
RECORD_ORIGIN=false
YES=false
SKIP_MERGES=false

usage() {
	cat <<'EOF'
Usage: prepare-branch-rebase.sh --since-tag <tag> [options]

Rebuild a branch on upstream and cherry-pick downstream commits since a tag.

Required:
  --since-tag <tag>         Pick commits reachable from SOURCE but not from TAG
                            (equivalent to: git rev-list --reverse TAG..SOURCE)

Options:
  --source <branch>         Branch with commits to replay (default: main)
  --target <branch>         Integration branch to create/reset (default: next)
  --upstream <remote>       Upstream remote name (default: upstream)
  --upstream-branch <br>    Upstream branch to fetch (default: main)
  --upstream-tag <tag>      Reset TARGET to this upstream tag instead of branch tip
                            (fetched from UPSTREAM; falls back to a local tag if the
                            commit is reachable from UPSTREAM/UPSTREAM-BRANCH)
  -i, --interactive         Prompt before each cherry-pick (y/n/skip/quit/all)
  -x                        Pass -x to cherry-pick (record original commit in message)
  --skip-merges             Skip merge commits instead of cherry-picking with -m 1
  --dry-run                 Show planned actions without changing branches
  -y, --yes                 Skip confirmation when resetting an existing TARGET branch
  -h, --help                Show this help

Interactive keys (when -i is set):
  y/Enter   cherry-pick this commit
  n         skip this commit
  a         cherry-pick this and all remaining commits without further prompts
  q         stop picking; leave TARGET at the last successful pick

On cherry-pick conflict the script pauses. Resolve conflicts manually in your
editor, stage the fixes, then choose continue/skip/quit from the prompt.
Re-run with the same arguments to resume after quitting mid-run; already-picked
commits are skipped.

Conflict keys:
  c/Enter   continue after resolving conflicts
  s         skip this commit and continue with the next
  q         stop the script; branch stays at the last successful pick

Empty-pick keys:
  e         record an empty commit anyway
  s         skip this commit and continue with the next
  q         stop the script; branch stays at the last successful pick
EOF
}

cherry_pick_in_progress() {
	git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1
}

list_conflicted_files() {
	git diff --name-only --diff-filter=U 2>/dev/null || true
}

is_empty_cherry_pick() {
	cherry_pick_in_progress || return 1
	[[ -z "$(list_conflicted_files)" ]] || return 1
	git diff --quiet && git diff --cached --quiet
}

finish_cherry_pick_skip() {
	if git cherry-pick --skip 2>/dev/null; then
		return 0
	fi
	git cherry-pick --abort 2>/dev/null || true
}

wait_for_manual_conflict_resolution() {
	local commit="$1"

	echo ""
	if is_empty_cherry_pick; then
		echo "==> Cherry-pick is empty (changes likely already on this branch)"
	else
		echo "==> Cherry-pick paused: resolve conflicts manually"
	fi
	git --no-pager log -1 --format='  commit: %h %s' "${commit}"
	echo ""
	if is_empty_cherry_pick; then
		echo "  Nothing to apply for this commit. Skip it and continue, or quit."
	else
		echo "  Conflicted files:"
		local files
		files="$(list_conflicted_files)"
		if [[ -n "${files}" ]]; then
			echo "${files}" | sed 's/^/    /'
		else
			echo "    (none listed yet — check git status)"
		fi
		echo ""
		echo "  1. Edit the conflicted files and remove conflict markers"
		echo "  2. Stage resolved files: git add <file> ..."
	fi
	echo ""

	if ! cherry_pick_in_progress; then
		die "cherry-pick state was lost before resolution could start"
	fi

	while cherry_pick_in_progress; do
		if is_empty_cherry_pick; then
			read -r -p "  [s]kip / [e] commit empty / [q]uit: " choice
			case "${choice}" in
			e | E)
				if git commit --allow-empty --no-edit; then
					echo "  recorded empty commit"
					return 0
				fi
				echo "  empty commit failed — try skip instead"
				;;
			s | S)
				finish_cherry_pick_skip
				echo "  skipped $(git --no-pager log -1 --format='%h %s' "${commit}")"
				return 2
				;;
			q | Q)
				git cherry-pick --abort 2>/dev/null || true
				echo ""
				echo "Stopped. Branch is at the last successful pick."
				echo "Re-run this script with the same arguments to resume."
				exit 0
				;;
			*)
				echo "  invalid choice; use e, s, or q"
				;;
			esac
		else
			read -r -p "  [c]ontinue / [s]kip / [q]uit: " choice
			case "${choice:-c}" in
			c | C | "")
				if [[ -z "$(list_conflicted_files)" ]]; then
					if git cherry-pick --continue; then
						echo "  cherry-pick continued successfully"
						return 0
					fi
					echo "  continue failed — check status and try again"
				else
					echo "  unresolved conflicts remain:"
					list_conflicted_files | sed 's/^/    /'
				fi
				;;
			s | S)
				finish_cherry_pick_skip
				echo "  skipped $(git --no-pager log -1 --format='%h %s' "${commit}")"
				return 2
				;;
			q | Q)
				git cherry-pick --abort 2>/dev/null || true
				echo ""
				echo "Stopped. Branch is at the last successful pick."
				echo "Re-run this script with the same arguments to resume."
				exit 0
				;;
			*)
				echo "  invalid choice; use c, s, or q"
				;;
			esac
		fi
	done

	die "cherry-pick state was cleared unexpectedly"
}

die() {
	echo "error: $*" >&2
	exit 1
}

print_colored_commit() {
	local commit="$1"
	local prefix="${2:-  }"
	git --no-pager -c color.ui=always log -1 --color=always --decorate=short \
		--format="${prefix}%C(auto)%h%d%Creset %s" "${commit}"
}

print_pick_separator() {
	echo ""
	printf '\033[2m────────────────────────────────────────\033[0m\n'
	echo ""
}

run_git() {
	if [[ "${DRY_RUN}" == "true" ]]; then
		echo "  [dry-run] git $*"
	else
		git "$@"
	fi
}

fetch_upstream_tag() {
	local tag="$1"
	local remote="$2"

	echo "==> Resolving upstream tag ${tag}..."
	if [[ "${DRY_RUN}" == "true" ]]; then
		echo "  [dry-run] git fetch ${remote} refs/tags/${tag}:refs/tags/${tag}"
	elif git fetch "${remote}" "refs/tags/${tag}:refs/tags/${tag}" 2>/dev/null; then
		echo "  fetched from ${remote}"
	elif git rev-parse --verify "${tag}^{commit}" >/dev/null 2>&1; then
		echo "  not on ${remote}; using local tag ${tag}"
	else
		die "upstream tag '${tag}' not found on ${remote} or locally"
	fi
}

is_merge_commit() {
	local parents
	parents="$(git rev-list --parents -n 1 "${1}" 2>/dev/null || true)"
	[[ "$(wc -w <<<"${parents}")" -gt 2 ]]
}

already_picked() {
	local commit="$1"
	git merge-base --is-ancestor "${commit}" HEAD 2>/dev/null
}

run_cherry_pick() {
	local commit="$1"
	shift
	# "${@}" may be empty; avoid "unbound variable" with set -u on macOS bash.
	if [[ $# -gt 0 ]]; then
		git cherry-pick "$@" "${commit}"
	else
		git cherry-pick "${commit}"
	fi
}

cherry_pick_commit() {
	local commit="$1"
	local args=()

	if [[ "${RECORD_ORIGIN}" == "true" ]]; then
		args+=(-x)
	fi

	if is_merge_commit "${commit}"; then
		if [[ "${SKIP_MERGES}" == "true" ]]; then
			echo "  skip merge ${commit}"
			return 0
		fi
		args+=(-m 1)
	fi

	if [[ "${DRY_RUN}" == "true" ]]; then
		if [[ ${#args[@]} -gt 0 ]]; then
			echo "  [dry-run] git cherry-pick ${args[*]} ${commit}"
		else
			echo "  [dry-run] git cherry-pick ${commit}"
		fi
		return 0
	fi

	if [[ ${#args[@]} -gt 0 ]]; then
		if run_cherry_pick "${commit}" "${args[@]}"; then
			return 0
		fi
	elif run_cherry_pick "${commit}"; then
		return 0
	fi

	if cherry_pick_in_progress; then
		wait_for_manual_conflict_resolution "${commit}"
		return $?
	fi

	die "cherry-pick failed for ${commit} ($(git --no-pager log -1 --oneline "${commit}"))"
}

prompt_pick() {
	local commit="$1"
	git --no-pager -c color.ui=always log -1 --color=always --decorate=short \
		--format='  %C(auto)%h%d%Creset %s %C(dim)(%an, %cr)%Creset' "${commit}"
	while true; do
		read -r -p "  Pick? [Y/n/q/a] " choice
		case "${choice:-y}" in
		y | Y | "") return 0 ;;
		n | N) return 1 ;;
		a | A) INTERACTIVE=false; return 0 ;;
		q | Q) return 2 ;;
		*) echo "  invalid choice; use y, n, q, or a" ;;
		esac
	done
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--since-tag)
		[[ $# -ge 2 ]] || die "--since-tag requires a value"
		SINCE_TAG="$2"
		shift 2
		;;
	--source)
		[[ $# -ge 2 ]] || die "--source requires a value"
		SOURCE_BRANCH="$2"
		shift 2
		;;
	--target)
		[[ $# -ge 2 ]] || die "--target requires a value"
		TARGET_BRANCH="$2"
		shift 2
		;;
	--upstream)
		[[ $# -ge 2 ]] || die "--upstream requires a value"
		UPSTREAM_REMOTE="$2"
		shift 2
		;;
	--upstream-branch)
		[[ $# -ge 2 ]] || die "--upstream-branch requires a value"
		UPSTREAM_BRANCH="$2"
		shift 2
		;;
	--upstream-tag)
		[[ $# -ge 2 ]] || die "--upstream-tag requires a value"
		UPSTREAM_TAG="$2"
		shift 2
		;;
	-i | --interactive) INTERACTIVE=true; shift ;;
	-x) RECORD_ORIGIN=true; shift ;;
	--skip-merges) SKIP_MERGES=true; shift ;;
	--dry-run) DRY_RUN=true; shift ;;
	-y | --yes) YES=true; shift ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
done

[[ -n "${SINCE_TAG}" ]] || {
	usage
	die "--since-tag is required"
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

if [[ "${DRY_RUN}" != "true" ]]; then
	if [[ -n "$(git status --porcelain)" ]]; then
		die "working tree is not clean; commit or stash changes first"
	fi
fi

ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
UPSTREAM_REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"

echo "==> Fetching ${UPSTREAM_REMOTE}..."
run_git fetch "${UPSTREAM_REMOTE}" "${UPSTREAM_BRANCH}"
if [[ -n "${UPSTREAM_TAG}" ]]; then
	fetch_upstream_tag "${UPSTREAM_TAG}" "${UPSTREAM_REMOTE}"
fi

git show-ref --verify --quiet "refs/remotes/${UPSTREAM_REF}" ||
	die "missing ${UPSTREAM_REF}; fetch ${UPSTREAM_REMOTE} first"

if [[ -n "${UPSTREAM_TAG}" ]]; then
	git rev-parse --verify "${UPSTREAM_TAG}^{commit}" >/dev/null 2>&1 ||
		die "upstream tag '${UPSTREAM_TAG}' does not resolve to a commit"
	git merge-base --is-ancestor "${UPSTREAM_TAG}" "${UPSTREAM_REF}" ||
		die "upstream tag '${UPSTREAM_TAG}' is not reachable from '${UPSTREAM_REF}'"
	UPSTREAM_BASE="${UPSTREAM_TAG}"
else
	UPSTREAM_BASE="${UPSTREAM_REF}"
fi

git show-ref --verify --quiet "refs/heads/${SOURCE_BRANCH}" ||
	die "source branch '${SOURCE_BRANCH}' does not exist"

git rev-parse --verify "${SINCE_TAG}^{commit}" >/dev/null 2>&1 ||
	die "tag '${SINCE_TAG}' not found or does not resolve to a commit"

git merge-base --is-ancestor "${SINCE_TAG}" "${SOURCE_BRANCH}" ||
	die "tag '${SINCE_TAG}' is not an ancestor of '${SOURCE_BRANCH}'"

COMMITS=()
while IFS= read -r commit; do
	[[ -n "${commit}" ]] && COMMITS+=("${commit}")
done < <(git rev-list --reverse "${SINCE_TAG}..${SOURCE_BRANCH}")
[[ ${#COMMITS[@]} -gt 0 ]] || die "no commits between ${SINCE_TAG} and ${SOURCE_BRANCH}"

echo ""
echo "Plan:"
if [[ -n "${UPSTREAM_TAG}" ]]; then
	echo "  upstream base : ${UPSTREAM_TAG} ($(git --no-pager log -1 --oneline "${UPSTREAM_TAG}"))"
	echo "  upstream tip  : ${UPSTREAM_REF} ($(git --no-pager log -1 --oneline "${UPSTREAM_REF}"))"
else
	echo "  upstream base : ${UPSTREAM_REF} ($(git --no-pager log -1 --oneline "${UPSTREAM_REF}"))"
fi
echo "  source branch : ${SOURCE_BRANCH} ($(git --no-pager log -1 --oneline "${SOURCE_BRANCH}"))"
echo "  since tag     : ${SINCE_TAG} ($(git --no-pager log -1 --oneline "${SINCE_TAG}"))"
echo "  target branch : ${TARGET_BRANCH}"
echo "  commits to consider: ${#COMMITS[@]}"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
	echo "Commits (${SINCE_TAG}..${SOURCE_BRANCH}, oldest first):"
	print_colored_commit "${COMMITS[0]}"
	if [[ ${#COMMITS[@]} -gt 1 ]]; then
		if [[ ${#COMMITS[@]} -gt 2 ]]; then
			echo "  ..."
			echo "  (${#COMMITS[@]} commits total)"
		fi
		print_colored_commit "${COMMITS[$((${#COMMITS[@]} - 1))]}"
	fi
	echo ""
	echo "Dry run complete; no branches were modified."
	exit 0
fi

if git show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}"; then
	if [[ "${YES}" != "true" ]]; then
		read -r -p "Branch '${TARGET_BRANCH}' exists and will be reset to ${UPSTREAM_BASE}. Continue? [y/N] " confirm
		[[ "${confirm}" =~ ^[Yy]$ ]] || die "aborted"
	fi
fi

echo "==> Preparing ${TARGET_BRANCH} at ${UPSTREAM_BASE}..."
if [[ "${ORIGINAL_BRANCH}" == "${TARGET_BRANCH}" ]]; then
	run_git checkout "${SOURCE_BRANCH}"
fi

if git show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}"; then
	run_git checkout "${TARGET_BRANCH}"
	run_git reset --hard "${UPSTREAM_BASE}"
else
	run_git checkout -b "${TARGET_BRANCH}" "${UPSTREAM_BASE}"
fi

PICKED=()
SKIPPED=()
SHOW_PICK_SEPARATOR=false

echo ""
echo "==> Cherry-picking commits..."
for commit in "${COMMITS[@]}"; do
	if already_picked "${commit}"; then
		echo "  already picked $(git --no-pager log -1 --format='%h %s' "${commit}")"
		PICKED+=("${commit}")
		SHOW_PICK_SEPARATOR=true
		continue
	fi

	if [[ "${SHOW_PICK_SEPARATOR}" == "true" ]]; then
		print_pick_separator
	fi

	if [[ "${INTERACTIVE}" == "true" ]]; then
		prompt_pick "${commit}" || {
			rc=$?
			if [[ ${rc} -eq 2 ]]; then
				echo "  stopped on user request"
				break
			fi
			echo "  skipped ${commit}"
			SKIPPED+=("${commit}")
			SHOW_PICK_SEPARATOR=true
			continue
		}
	else
		print_colored_commit "${commit}" "  picking "
	fi

	# Use if/else so set -e does not exit when cherry_pick_commit returns non-zero.
	if cherry_pick_commit "${commit}"; then
		PICKED+=("${commit}")
		SHOW_PICK_SEPARATOR=true
	else
		rc=$?
		if [[ ${rc} -eq 2 ]]; then
			SKIPPED+=("${commit}")
			SHOW_PICK_SEPARATOR=true
			echo "  continuing with next commit..."
		else
			die "unexpected cherry-pick result for ${commit} (rc=${rc})"
		fi
	fi
done

echo ""
echo "==> Summary"
echo "Target branch: ${TARGET_BRANCH} @ $(git rev-parse --short HEAD)"
echo "Upstream base: ${UPSTREAM_BASE} @ $(git rev-parse --short "${UPSTREAM_BASE}")"
echo ""
echo "Picked (${#PICKED[@]}):"
if [[ ${#PICKED[@]} -eq 0 ]]; then
	echo "  (none)"
else
	for commit in "${PICKED[@]}"; do
		git --no-pager log -1 --format='  %h %s' "${commit}"
	done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
	echo ""
	echo "Skipped (${#SKIPPED[@]}):"
	for commit in "${SKIPPED[@]}"; do
		git --no-pager log -1 --format='  %h %s' "${commit}"
	done
fi

REMAINING=$(( ${#COMMITS[@]} - ${#PICKED[@]} - ${#SKIPPED[@]} ))
if [[ ${REMAINING} -gt 0 ]]; then
	echo ""
	echo "Remaining (not picked): ${REMAINING}"
fi

echo ""
echo "Done. You are on '${TARGET_BRANCH}'."