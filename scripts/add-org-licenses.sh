#!/usr/bin/env bash
# add-org-licenses.sh
#
# Adds the BSD-2-Clause-Patent LICENSE file to SiliconLanguage org repos that
# are missing it, creating a branch and opening a PR in each target repo.
#
# Prerequisites:
#   - gh CLI installed and authenticated (gh auth login)
#   - The authenticated user has write access to all TARGET_REPOS
#
# Usage:
#   ./scripts/add-org-licenses.sh [--dry-run] [repo1 repo2 ...]
#
#   If no repos are supplied the DEFAULT_REPOS list below is used.
#
# Examples:
#   ./scripts/add-org-licenses.sh --dry-run
#   ./scripts/add-org-licenses.sh m-store m-ipc monadic-hypervisor .github

set -euo pipefail

ORG="SiliconLanguage"
BRANCH="chore/add-bsd-2-clause-patent-license"
DEFAULT_REPOS="m-store m-ipc monadic-hypervisor .github"
DRY_RUN=false

# ── Argument parsing ──────────────────────────────────────────────────────────
REPOS=()
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN=true
  else
    REPOS+=("$arg")
  fi
done
if [[ ${#REPOS[@]} -eq 0 ]]; then
  IFS=' ' read -r -a REPOS <<< "$DEFAULT_REPOS"
fi

# ── LICENSE body ──────────────────────────────────────────────────────────────
LICENSE_BODY="Copyright (c) 2026 SiliconLanguage

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Subject to the terms and conditions of this license, each copyright holder and contributor hereby grants to those receiving rights under this license a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except for failure to satisfy the conditions of this license) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer this software, where such license applies only to those patent claims, already acquired or hereafter acquired, licensable by such copyright holder or contributor that are necessarily infringed by:

(a) their Contribution(s) (the licensed copyrights of copyright holders and non-copyrightable additions of contributors, in source or binary form) alone; or

(b) combination of their Contribution(s) with the work of authorship to which such Contribution(s) was added by such copyright holder or contributor, if, at the time the Contribution is added, such addition causes such combination to be necessarily infringed. The patent license shall not apply to any other combinations which include the Contribution.

Except as expressly stated above, no rights or licenses from any copyright holder or contributor is granted under this license, whether expressly, by implication, estoppel or otherwise.

DISCLAIMER

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "  ℹ $*"; }
ok()    { echo "  ✅ $*"; }
skip()  { echo "  ⏭  $*"; }

check_prereqs() {
  if ! command -v gh &> /dev/null; then
    echo "ERROR: gh CLI not found. Install from https://cli.github.com/"
    exit 1
  fi
  if ! gh auth status &> /dev/null; then
    echo "ERROR: gh CLI is not authenticated. Run: gh auth login"
    exit 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
check_prereqs

LICENSE_TMP=$(mktemp)
printf '%s\n' "$LICENSE_BODY" > "$LICENSE_TMP"
trap 'rm -f "$LICENSE_TMP"' EXIT

echo "Target org  : ${ORG}"
echo "Target repos: ${REPOS[*]}"
echo "Dry run     : ${DRY_RUN}"
echo ""

for REPO in "${REPOS[@]}"; do
  FULL_REPO="${ORG}/${REPO}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Processing: ${FULL_REPO}"

  # Check if LICENSE already matches
  EXISTING=$(gh api "repos/${FULL_REPO}/contents/LICENSE" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "$EXISTING" ]] && diff -q <(printf '%s\n' "$EXISTING") "$LICENSE_TMP" &>/dev/null; then
    skip "LICENSE already matches — skipping"
    continue
  fi

  # Get default branch
  DEFAULT_BRANCH=$(gh api "repos/${FULL_REPO}" --jq '.default_branch')
  info "Default branch: ${DEFAULT_BRANCH}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would create branch '${BRANCH}' and open PR"
    continue
  fi

  # Clone shallow copy, apply license, push
  CLONE_DIR=$(mktemp -d)
  trap 'rm -rf "$CLONE_DIR" "$LICENSE_TMP"' EXIT

  gh repo clone "${FULL_REPO}" "${CLONE_DIR}" -- --depth=1 --branch "${DEFAULT_BRANCH}" 2>/dev/null

  cd "${CLONE_DIR}"
  git config user.email "$(gh api user --jq '.email // "noreply@github.com"')"
  git config user.name  "$(gh api user --jq '.login')"

  # Reuse branch if it already exists remotely
  if git ls-remote --exit-code origin "${BRANCH}" &>/dev/null; then
    info "Branch '${BRANCH}' already exists remotely — fetching"
    git fetch origin "${BRANCH}"
    git checkout "${BRANCH}"
  else
    git checkout -b "${BRANCH}"
  fi

  cp "$LICENSE_TMP" LICENSE
  git add LICENSE

  if git diff --cached --quiet; then
    skip "No changes needed"
    cd /
    continue
  fi

  git commit -m "chore: add BSD-2-Clause-Patent license"
  git push origin "${BRANCH}"

  # Open PR (skip if one is already open)
  EXISTING_PR=$(gh pr list --repo "${FULL_REPO}" \
    --head "${BRANCH}" --json url --jq '.[0].url' 2>/dev/null || true)

  if [[ -n "$EXISTING_PR" ]]; then
    ok "PR already open: ${EXISTING_PR}"
  else
    PR_URL=$(gh pr create \
      --repo "${FULL_REPO}" \
      --base "${DEFAULT_BRANCH}" \
      --head "${BRANCH}" \
      --title "chore: add BSD-2-Clause-Patent license" \
      --body "Adds the [BSD-2-Clause-Patent](https://opensource.org/license/bsdpluspatent) license to align with the rest of the SiliconLanguage org (see [tensorplane](https://github.com/SiliconLanguage/tensorplane?tab=BSD-2-Clause-Patent-1-ov-file)).")
    ok "PR opened: ${PR_URL}"
  fi

  cd /
done

echo ""
echo "Done."
