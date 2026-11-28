#!/usr/bin/env bash
set -euo pipefail

upstream=starkware-libs/cairo-vm
repo=${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to the receiving repo}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Match published tags even if the maintainer has not created a GitHub Release.
gh api --paginate --slurp "repos/$upstream/tags?per_page=100" > "$scratch/tags"
gh api --paginate --slurp "repos/$repo/issues?state=all&creator=github-actions%5Bbot%5D&per_page=100" > "$scratch/issues"

jq -r --slurpfile baseline .github/upstream/cairo-vm-baseline.json --slurpfile issues "$scratch/issues" '
  def version: test("^v?[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$");
  def marker: "<!-- upstream-cairo-vm " + .name + " " + .commit.sha + " -->";
  ($issues[0] | add // [] | map(select(.pull_request == null) |
    (.body // "" | split("\n")[] | select(startswith("<!-- upstream-cairo-vm ")))) |
    INDEX(.)) as $reported |
  (add // [])[] |
  select(.name | version) |
  if (.commit.sha | test("^[0-9a-f]{40}$")) then . else error("invalid upstream commit") end |
  select($baseline[0][.name] != .commit.sha and $reported[marker] == null) |
  [.name, .commit.sha] | @tsv
' "$scratch/tags" > "$scratch/pending"

while IFS=$'\t' read -r tag sha; do
  cat > "$scratch/body" <<BODY
<!-- upstream-cairo-vm $tag $sha -->
Upstream tag [$tag](https://github.com/$upstream/tree/$tag) points to [$sha](https://github.com/$upstream/commit/$sha).

- [ ] Identify the affected reference: general CLI/VM, the sequencer-pinned OS and PIE contracts, or both. Record the relevant upstream changes.
- [ ] Compare this exact commit with the current reference on execution, typed refusals, trace, memory and PIE output as applicable. [Parity harness](https://github.com/$repo/blob/HEAD/.github/workflows/parity-harness.yml) · [Execution contract](https://github.com/$repo/blob/HEAD/docs/EXECUTION_CONTRACT.md)
- [ ] Record the compatibility decision and any failing cases. If adopting, update the appropriate immutable pins, fixtures and documentation in a reviewed PR.
BODY
  gh issue create --repo "$repo" --title "Qualify upstream cairo-vm $tag (${sha:0:8})" --body-file "$scratch/body"
done < "$scratch/pending"
count=$(wc -l < "$scratch/pending")
echo "Upstream cairo-vm tags checked; $((count)) compatibility issues opened."
