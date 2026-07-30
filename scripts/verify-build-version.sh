#!/usr/bin/env bash
set -euo pipefail

BASE="${1:?usage: verify-build-version.sh BASE [HEAD]}"
HEAD_REF="${2:-HEAD}"

git cat-file -e "$BASE^{commit}"
git cat-file -e "$HEAD_REF^{commit}"

app_files_changed() {
  local parent="$1"
  local commit="$2"
  local changed

  changed="$(git diff --name-only "$parent" "$commit")"
  grep -qE \
    '^(TiebaPure/|Protos/|project\.yml$|TiebaPure\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$)' \
    <<< "$changed"
}

build_number_at() {
  local commit="$1"

  git show "$commit:project.yml" |
    sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' |
    head -n 1
}

RANGE_BASE="$(git merge-base "$BASE" "$HEAD_REF")"

while IFS= read -r commit; do
  [[ -n "$commit" ]] || continue

  parent="$(git rev-parse "$commit^1")"
  if ! app_files_changed "$parent" "$commit"; then
    continue
  fi

  previous="$(build_number_at "$parent")"
  current="$(build_number_at "$commit")"
  short_commit="$(git rev-parse --short "$commit")"

  if [[ ! "$previous" =~ ^[0-9]+$ || ! "$current" =~ ^[0-9]+$ ]]; then
    echo "Unable to read CURRENT_PROJECT_VERSION for app-changing commit $short_commit." >&2
    exit 1
  fi

  if (( current <= previous )); then
    echo "App-changing commit $short_commit must increment CURRENT_PROJECT_VERSION (parent: $previous, commit: $current)." >&2
    echo "Update the value in project.yml, regenerate the Xcode project, and commit both files." >&2
    exit 1
  fi
done < <(git rev-list --reverse --first-parent "$RANGE_BASE..$HEAD_REF")
