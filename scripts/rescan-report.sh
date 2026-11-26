#!/usr/bin/env bash
#
# Turn one rescan's per-platform scan reports into a tracking-issue body, and a
# comment saying what changed since the last rescan, if anything did.
#
# No network and no GitHub calls: rescan.yml does those. Keeping the decision
# here means it can be run, and tested, on a laptop against real reports.
#
# State between runs lives in the issue body itself, as a base64 block in an
# HTML comment. There is no other store, so there is nothing to drift: the issue
# says what the last rescan saw, and this compares against exactly that.
#
# A change is any of: a finding that is new or gone, one that became fixable,
# a severity either scanner changed, or a platform whose digest moved. Database
# timestamps and scan times are NOT changes: they move every day, and a comment
# for each would bury the ones that matter.
#
#   usage: scripts/rescan-report.sh <tag> <previous-issue-body|-> <out-dir> <run-url> <scan-report.json>...
#
# writes, in <out-dir>:
#   body.md     new issue body, always
#   comment.md  only when something changed since the previous body
#   status      first | changed | unchanged
#
set -euo pipefail

TAG="${1:?usage: rescan-report.sh <tag> <prev-body|-> <out-dir> <run-url> <report.json>...}"
PREV="${2:?}"; OUT="${3:?}"; RUN_URL="${4:?}"; shift 4
(( $# > 0 )) || { echo "no scan reports given" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
mkdir -p "${OUT}"
rm -f "${OUT}/comment.md"

# --- current state, from the reports ------------------------------------------
jq -s --arg tag "${TAG}" '
  {
    v: 1, tag: $tag,
    scanned_at: (map(.scanned_at) | max),
    platforms: (map({key: .platform, value: {
        digest: (.image | split("@")[1]),
        counts: .counts, scanners: .scanners}}) | from_entries),
    findings: ([.[] as $r | $r.findings[] | {
        key: "\($r.platform)|\(.id)|\(.package)",
        value: {g: .grype.severity, t: .trivy.severity, fixable: .fixable,
                installed: .installed,
                fixed_in: (((.grype.fixed_in // []) + (.trivy.fixed_in // [])) | unique)}}]
      | from_entries)
  }' "$@" > "${OUT}/state.json"

# --- previous state, from the previous body -------------------------------------
prev_state="${OUT}/prev-state.json"
echo 'null' > "${prev_state}"
if [[ "${PREV}" != "-" && -s "${PREV}" ]]; then
  b64="$(grep -o 'rescan-state:[A-Za-z0-9+/=]*' "${PREV}" | head -1 | cut -d: -f2 || true)"
  if [[ -n "${b64}" ]] && printf '%s' "${b64}" | base64 -d 2>/dev/null | jq -e '.v == 1' >/dev/null 2>&1; then
    printf '%s' "${b64}" | base64 -d > "${prev_state}"
  else
    echo "WARNING: previous body has no readable rescan state; treating this as the first rescan" >&2
  fi
fi

# --- delta ----------------------------------------------------------------------
# Grouped by finding (id|package) so a CVE on both platforms is one line, with
# the platforms it applies to.
jq -n --slurpfile c "${OUT}/state.json" --slurpfile p "${prev_state}" '
  $c[0] as $c | $p[0] as $p
  | def grp: group_by(.k) | map({k: .[0].k, plats: (map(.plat) | unique), cur: .[0].cur, old: .[0].old});
    def split3: . as $key | ($key | split("|")) as $s
      | {plat: $s[0], k: "\($s[1])|\($s[2])"};
  if $p == null then {first: true} else
  ($c.findings | keys) as $ck | ($p.findings | keys) as $pk
  | {
      first: false,
      new:  [($ck - $pk)[] | split3 + {cur: $c.findings[.]}] | grp,
      gone: [($pk - $ck)[] | split3 + {old: $p.findings[.]}] | grp,
      fixable: [($ck - ($ck - $pk))[] | select($c.findings[.].fixable and ($p.findings[.].fixable | not))
                | split3 + {cur: $c.findings[.]}] | grp,
      severity: [($ck - ($ck - $pk))[]
                 | select($c.findings[.].g != $p.findings[.].g or $c.findings[.].t != $p.findings[.].t)
                 | split3 + {cur: $c.findings[.], old: $p.findings[.]}] | grp,
      digests: [$c.platforms | to_entries[]
                | select(($p.platforms[.key].digest // "") != .value.digest)
                | {plat: .key, old: ($p.platforms[.key].digest // null), cur: .value.digest}]
    }
  end' > "${OUT}/delta.json"

status="$(jq -r 'if .first then "first"
                 elif ([.new, .gone, .fixable, .severity, .digests] | map(length) | add) > 0 then "changed"
                 else "unchanged" end' "${OUT}/delta.json")"
echo "${status}" > "${OUT}/status"

# --- body -----------------------------------------------------------------------
sev() { cat <<'JQ'
def sevrank: {"critical":0,"high":1,"medium":2,"low":3,"negligible":4,"unknown":5}[. // "unknown"] // 6;
def sv: . // "—";
JQ
}
jq -r --arg run "${RUN_URL}" "$(sev)"'
  . as $s
  | ($s.platforms | to_entries) as $pl
  | ([$s.findings | to_entries[] | (.key | split("|")) as $k
      | {id: $k[1], pkg: $k[2], plat: $k[0]} + .value]
     | group_by("\(.id)|\(.pkg)")
     | map(.[0] + {plats: (map(.plat) | unique | join(", "))})) as $F
  | "## Daily rescan: `ghcr.io/thefutoneng/bitcoin:\($s.tag)`",
    "",
    "Last scanned **\($s.scanned_at)** ([run](\($run))). Report only: nothing here fails a release. Comments below appear only when the findings change.",
    "",
    "| platform | digest | findings | Grype C / H | Trivy C / H | fixable |",
    "|---|---|---|---|---|---|",
    ($pl[] | .value.counts as $n
     | "| `\(.key)` | `\(.value.digest[7:19])…` | \($n.findings) | \($n.grype.critical // 0) / \($n.grype.high // 0) | \($n.trivy.critical // 0) / \($n.trivy.high // 0) | \($n.fixable) |"),
    "",
    ($pl[0].value.scanners as $sc
     | "Scanners: grype \($sc.grype.version) (db built \($sc.grype.db.built)), trivy \($sc.trivy.version) (db updated \($sc.trivy.db.updated_at))."),
    "",
    "### Fixable",
    "",
    (if ([$F[] | select(.fixable)] | length) == 0 then "None." else
      ($F | map(select(.fixable)) | sort_by(.pkg, .id)[]
       | "- **\(.id)** `\(.pkg)` \(.installed) → \(.fixed_in | join(", ")) (\(.plats))") end),
    "",
    "### Critical or High by either scanner",
    "",
    (if ([$F[] | select(([.g, .t] | map(sevrank) | min) <= 1)] | length) == 0 then "None." else
      ($F | map(select(([.g, .t] | map(sevrank) | min) <= 1))
          | sort_by(([.g, .t] | map(sevrank) | min), .id)[]
       | "- **\(.id)** `\(.pkg)`: grype \(.g | sv) / trivy \(.t | sv) (\(.plats))") end),
    "",
    "<!-- rescan-state:\($s | tojson | @base64) -->"
' "${OUT}/state.json" > "${OUT}/body.md"

# --- comment, only on change --------------------------------------------------------
if [[ "${status}" == "changed" ]]; then
  jq -r --arg run "${RUN_URL}" --slurpfile p "${prev_state}" "$(sev)"'
    def line: (.k | split("|")) as $k | "- **\($k[0])** `\($k[1])`";
    "Findings changed since the rescan of \($p[0].scanned_at) ([run](\($run))):",
    "",
    (if (.digests | length) > 0 then "**Image digest changed**",
      (.digests[] | "- `\(.plat)`: `\(.old // "none")` → `\(.cur)`"), "" else empty end),
    (if (.fixable | length) > 0 then "**Now fixable (\(.fixable | length))**",
      (.fixable[] | "\(line) → \(.cur.fixed_in | join(", ")) (\(.plats | join(", ")))"), "" else empty end),
    (if (.new | length) > 0 then "**New (\(.new | length))**",
      (.new | sort_by(([.cur.g, .cur.t] | map(sevrank) | min))[]
       | "\(line): grype \(.cur.g | sv) / trivy \(.cur.t | sv) (\(.plats | join(", ")))"), "" else empty end),
    (if (.severity | length) > 0 then "**Severity changed (\(.severity | length))**",
      (.severity[] | . as $f
       | ([if $f.old.g != $f.cur.g then "grype \($f.old.g | sv) → \($f.cur.g | sv)" else empty end,
           if $f.old.t != $f.cur.t then "trivy \($f.old.t | sv) → \($f.cur.t | sv)" else empty end] | join(", ")) as $chg
       | "\(line): \($chg) (\(.plats | join(", ")))"), "" else empty end),
    (if (.gone | length) > 0 then "**Gone (\(.gone | length))**",
      (.gone[] | "\(line) (\(.plats | join(", ")))"), "" else empty end)
  ' "${OUT}/delta.json" > "${OUT}/comment.md"
fi

echo "${status}"
