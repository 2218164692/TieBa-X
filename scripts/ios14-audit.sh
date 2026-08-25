#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
GIT=(git -c "safe.directory=$ROOT")

fail() {
    echo "ios14-audit: $*" >&2
    exit 1
}

grep -Fq 'iOS: "14.0"' project.yml \
    || fail "project.yml does not declare iOS 14.0 deployment"
grep -Fq 'IPHONEOS_DEPLOYMENT_TARGET: 14.0' project.yml \
    || fail "project.yml is missing the iOS 14 build setting"

swift_files="$("${GIT[@]}" ls-files 'TiebaPure' | grep '\.swift$' || true)"
[[ -n "$swift_files" ]] || fail "no TieBa-X Swift sources found"

is_compat_file() {
    case "$1" in
        TiebaPure/Core/UI/TieBaXSwiftUICompat.swift|\
        TiebaPure/Core/UI/TieBaXNavigationCompat.swift|\
        TiebaPure/Core/Network/TieBaXURLCompat.swift|\
        TiebaPure/Core/Network/TieBaXURLSessionCompat.swift|\
        TiebaPure/Core/Concurrency/TieBaXTaskCompat.swift|\
        TiebaPure/Core/UI/TieBaXPhotoPicker.swift)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

assert_absent_outside_compat() {
    local pattern="$1"
    local description="$2"
    local matches
    matches="$("${GIT[@]}" grep -nE "$pattern" -- TiebaPure || true)"
    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        local path="${match%%:*}"
        [[ "$path" == *.swift ]] || continue
        is_compat_file "$path" && continue
        printf '%s\n' "$match" >&2
        fail "unwrapped iOS 15+ API: $description ($path)"
    done <<< "$matches"
}

assert_only_in_files() {
    local pattern="$1"
    local description="$2"
    shift 2
    local matches
    matches="$("${GIT[@]}" grep -nE "$pattern" -- TiebaPure || true)"
    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        local path="${match%%:*}"
        [[ "$path" == *.swift ]] || continue
        local allowed=1
        for expected in "$@"; do
            if [[ "$path" == "$expected" ]]; then
                allowed=0
                break
            fi
        done
        if [[ "$allowed" -ne 0 ]]; then
            printf '%s\n' "$match" >&2
            fail "unexpected availability-sensitive API: $description ($path)"
        fi
    done <<< "$matches"
}

# These modifiers/types must only be referenced by the TieBa-X compatibility
# layer. This catches accidental reintroduction of an iOS 15+ call at a feature
# call site before Xcode has to diagnose it.
assert_absent_outside_compat '\.task[[:space:]]*\(' '.task'
assert_absent_outside_compat '\.refreshable[[:space:]]*\(' '.refreshable'
assert_absent_outside_compat '\.searchable[[:space:]]*\(' '.searchable'
assert_absent_outside_compat '\.safeAreaInset[[:space:]]*\(' '.safeAreaInset'
assert_absent_outside_compat '\.scrollDismissesKeyboard[[:space:]]*\(' '.scrollDismissesKeyboard'
assert_absent_outside_compat '\.scrollContentBackground[[:space:]]*\(' '.scrollContentBackground'
assert_absent_outside_compat '\.scrollIndicators[[:space:]]*\(' '.scrollIndicators'
assert_absent_outside_compat '\.scrollBounceBehavior[[:space:]]*\(' '.scrollBounceBehavior'
assert_absent_outside_compat '\.foregroundStyle[[:space:]]*\(' '.foregroundStyle'
assert_absent_outside_compat '\.controlSize[[:space:]]*\(' '.controlSize'
assert_absent_outside_compat '\.textSelection[[:space:]]*\(' '.textSelection'
assert_absent_outside_compat '\.dynamicTypeSize[[:space:]]*\(' '.dynamicTypeSize'
assert_absent_outside_compat '\.symbolRenderingMode[[:space:]]*\(' '.symbolRenderingMode'
assert_absent_outside_compat '\.interactiveDismissDisabled[[:space:]]*\(' '.interactiveDismissDisabled'
assert_absent_outside_compat '\.swipeActions[[:space:]]*\(' '.swipeActions'
assert_absent_outside_compat '\.listRowSeparator[[:space:]]*\(' '.listRowSeparator'
assert_absent_outside_compat '(^|[^[:alnum:]_])(PhotosPicker|ShareLink|LabeledContent|ViewThatFits|NavigationStack)[[:space:]]*\(' 'direct iOS 15+ SwiftUI type'

# APIs that are intentionally kept in a feature file are checked against a
# short allowlist; each call site remains guarded by an availability branch.
assert_only_in_files '\.bytes[[:space:]]*\([[:space:]]*for:' '.bytes(for:)' \
    TiebaPure/Core/Network/TiebaHTTPClient.swift \
    TiebaPure/Core/Network/TiebaPostingBootstrap.swift \
    TiebaPure/Core/Network/TieBaXURLSessionCompat.swift
assert_only_in_files 'TimelineView[[:space:]]*\(' 'TimelineView' \
    TiebaPure/Core/UI/ShortPullRefresh.swift
assert_only_in_files 'NavigationSplitView' 'NavigationSplitView' \
    TiebaPure/Core/UI/ReaderSplitLayout.swift
assert_only_in_files 'CAFrameRateRange|preferredFrameRateRange' 'frame-rate API' \
    TiebaPure/Features/Media/ImageViewer.swift \
    TiebaPure/Features/Media/MediaPreviewHeroAnimator.swift
assert_only_in_files 'UIButton\.Configuration' 'UIButton.Configuration' \
    TiebaPure/Features/Media/ImageViewer.swift \
    TiebaPure/Features/Media/VideoPreviewTransition.swift
assert_only_in_files 'sizingRule|registerForTraitChanges' 'trait sizing API' \
    TiebaPure/Features/Thread/ContentBlockView.swift
assert_only_in_files 'presentationDetents|presentationDragIndicator|presentationBackground' 'sheet presentation API' \
    TiebaPure/Features/Thread/ThreadDetailView.swift
assert_only_in_files '\.spring[[:space:]]*\([[:space:]]*duration:' 'spring duration API' \
    TiebaPure/Features/Thread/SubpostSheetInteractiveDismiss.swift
assert_only_in_files 'onScrollVisibilityChange' 'scroll visibility API' \
    TiebaPure/Features/Thread/ThreadDetailView.swift

echo "ios14-audit: deployment target, compatibility call sites, and availability allowlists OK"
