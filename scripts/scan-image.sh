#!/usr/bin/env bash
#
# Scan one platform image with two scanners and report where they differ.
#
#   Grype scans the SBOM — the one the release attests, so its findings are
#         tied to signed evidence about these exact bytes.
#   Trivy scans the image itself, so it does not inherit syft's view of what
#         the image contains.
#
# Why both, measured on 31.1-3 before this existed: the scanners reported the
# same eight CVEs and disagreed completely on severity — Grype 2 Critical and
# 6 High, Trivy none — because Debian had not rated them and each fell back to a
# different source (NVD for Grype, other distros for Trivy). Either answer
# alone would have been confident and arbitrary. So this reports:
#
#   - each finding, and which scanner(s) saw it
#   - where the two disagree on severity
#   - which findings have a fix available upstream
#   - which PACKAGES only one tool saw — a package one scanner cannot see is a
#     blind spot for every CVE in it, which matters more than any one finding
#
# REPORT ONLY, by decision: findings never fail this script. A scan that did not
# happen is a different matter — an absent or empty result is not evidence of a
# clean image — so a scanner that fails, or inventories nothing, fails the run.
#
# The report records each scanner's version and vulnerability-database identity:
# the same image scanned tomorrow can report differently purely because the
# database moved, and a result without its database is not reproducible.
#
#   usage: scripts/scan-image.sh <image@sha256:platform-digest> <platform> <sbom.spdx.json> <report.json>
#
# env:
#   SCANNER_BIN=   where grype and trivy live (default: <repo>/.tools/bin, then PATH)
#
set -euo pipefail

IMAGE="${1:?usage: scan-image.sh <image@digest> <platform> <sbom.spdx.json> <report.json>}"
PLATFORM="${2:?usage: scan-image.sh <image@digest> <platform> <sbom.spdx.json> <report.json>}"
SBOM="${3:?usage: scan-image.sh <image@digest> <platform> <sbom.spdx.json> <report.json>}"
REPORT="${4:?usage: scan-image.sh <image@digest> <platform> <sbom.spdx.json> <report.json>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER_BIN="${SCANNER_BIN:-${REPO_ROOT}/.tools/bin}"
PATH="${SCANNER_BIN}:${PATH}"
for t in grype trivy jq; do
  command -v "${t}" >/dev/null || { echo "${t} not found — run scripts/install-scanners.sh" >&2; exit 1; }
done

# By digest only: a tag can move between the two scans, and then the report
# would describe two different images as one.
[[ "${IMAGE}" == *@sha256:* ]] || { echo "scan by platform digest, not by tag: ${IMAGE}" >&2; exit 1; }
digest="${IMAGE##*@}"
[[ -f "${SBOM}" ]] || { echo "no SBOM at ${SBOM}" >&2; exit 1; }
# The SBOM must describe THIS image, or Grype would scan some other image's
# package list and the report would attribute its findings here. The same
# binding check sign-image.sh makes before attesting.
jq -e --arg d "${digest}" 'any(.packages[]; .versionInfo == $d)' "${SBOM}" >/dev/null \
  || { echo "FATAL: ${SBOM} does not describe ${digest}" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo ">> ${PLATFORM}  ${IMAGE}"

# --- run both; either failing is fatal ---------------------------------------
grype "sbom:${SBOM}" -o json --file "${tmp}/grype.json" -q 2>"${tmp}/grype.err" \
  || { echo "grype failed:" >&2; sed 's/^/  /' "${tmp}/grype.err" >&2; exit 1; }
trivy image -q --platform "${PLATFORM}" --scanners vuln --list-all-pkgs \
  --format json --output "${tmp}/trivy.json" "${IMAGE}" 2>"${tmp}/trivy.err" \
  || { echo "trivy failed:" >&2; sed 's/^/  /' "${tmp}/trivy.err" >&2; exit 1; }

grype db status -o json > "${tmp}/grype-db.json" 2>/dev/null \
  || { echo "cannot read grype's database status" >&2; exit 1; }
trivy version --format json > "${tmp}/trivy-version.json" 2>/dev/null \
  || { echo "cannot read trivy's version and database" >&2; exit 1; }
grype_version="$(grype version -o json 2>/dev/null | jq -r .version)"

# --- combine -------------------------------------------------------------------
# Packages are compared by name. The SBOM's entry for the image itself (whose
# versionInfo is a digest) is not a package.
jq -n \
  --arg image "${IMAGE}" --arg platform "${PLATFORM}" \
  --arg scanned_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sbom_sha256 "$(sha256sum "${SBOM}" | cut -d' ' -f1)" \
  --arg grype_version "${grype_version}" \
  --slurpfile g "${tmp}/grype.json" --slurpfile t "${tmp}/trivy.json" \
  --slurpfile gdb "${tmp}/grype-db.json" --slurpfile tv "${tmp}/trivy-version.json" \
  --slurpfile sbom "${SBOM}" '
  def sev: ascii_downcase;
  ($g[0].matches // []) as $gm
  | ([$t[0].Results[]?.Vulnerabilities[]?]) as $tv_
  | ([$sbom[0].packages[] | select((.versionInfo // "") | startswith("sha256:") | not) | .name] | unique) as $gp
  | ([$t[0].Results[]?.Packages[]?.Name] | unique) as $tp
  | ([$gm[] | {key: "\(.vulnerability.id)|\(.artifact.name)",
               value: {id: .vulnerability.id, package: .artifact.name, installed: .artifact.version,
                       grype: {severity: (.vulnerability.severity | sev),
                               fix_state: .vulnerability.fix.state,
                               fixed_in: (.vulnerability.fix.versions // [])}}}] | from_entries) as $G
  | ([$tv_[] | {key: "\(.VulnerabilityID)|\(.PkgName)",
                value: {id: .VulnerabilityID, package: .PkgName, installed: .InstalledVersion,
                        trivy: {severity: (.Severity | sev), status: .Status,
                                fixed_in: ([.FixedVersion // empty] | map(select(. != "")))}}}] | from_entries) as $T
  | ([($G | keys[]), ($T | keys[])] | unique
     | map(($G[.] // {}) * ($T[.] // {})
           | .seen_by = ([if .grype then "grype" else empty end, if .trivy then "trivy" else empty end])
           | .severity_disagrees = (.grype != null and .trivy != null and .grype.severity != .trivy.severity)
           | .fixable = (((.grype.fixed_in // []) + (.trivy.fixed_in // [])) | length > 0))
     | sort_by(.package, .id)) as $F
  | {
      predicate_version: 1,
      policy: "report-only",
      image: $image, platform: $platform, scanned_at: $scanned_at,
      sbom_sha256: $sbom_sha256,
      scanners: {
        grype: {version: $grype_version, scanned: "sbom",
                db: {schema: $gdb[0].schemaVersion, built: $gdb[0].built, source: $gdb[0].from}},
        trivy: {version: $tv[0].Version, scanned: "image",
                db: {version: $tv[0].VulnerabilityDB.Version, updated_at: $tv[0].VulnerabilityDB.UpdatedAt}}
      },
      packages: {grype: ($gp | length), trivy: ($tp | length),
                 only_grype: ($gp - $tp), only_trivy: ($tp - $gp)},
      counts: {
        grype: ([$F[] | select(.grype) | .grype.severity] | group_by(.) | map({key: .[0], value: length}) | from_entries),
        trivy: ([$F[] | select(.trivy) | .trivy.severity] | group_by(.) | map({key: .[0], value: length}) | from_entries),
        findings: ($F | length),
        both: ([$F[] | select(.seen_by | length == 2)] | length),
        only_grype: ([$F[] | select(.seen_by == ["grype"])] | length),
        only_trivy: ([$F[] | select(.seen_by == ["trivy"])] | length),
        severity_disagrees: ([$F[] | select(.severity_disagrees)] | length),
        fixable: ([$F[] | select(.fixable)] | length)
      },
      findings: $F
    }' > "${tmp}/report.json"

# --- a scan that saw nothing did not happen ------------------------------------
# Every real image here has at least libc6. Zero packages means a scanner could
# not read the image or the SBOM — and would report "no vulnerabilities".
n_g="$(jq '.packages.grype' "${tmp}/report.json")"; n_t="$(jq '.packages.trivy' "${tmp}/report.json")"
if (( n_g == 0 || n_t == 0 )); then
  echo "FATAL: a scanner inventoried nothing (grype ${n_g}, trivy ${n_t} packages) — not a clean result, no result" >&2
  exit 1
fi

mkdir -p "$(dirname "${REPORT}")"
cp "${tmp}/report.json" "${REPORT}"

# --- human summary -------------------------------------------------------------
jq -r '
  def sevs: to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(" ") | if . == "" then "none" else . end;
  "   scanners   grype \(.scanners.grype.version) (db built \(.scanners.grype.db.built)) · trivy \(.scanners.trivy.version) (db \(.scanners.trivy.db.updated_at))",
  "   packages   grype saw \(.packages.grype), trivy saw \(.packages.trivy)"
    + (if (.packages.only_grype + .packages.only_trivy | length) == 0 then " — same set"
       else " — only grype: \(.packages.only_grype | join(",")) · only trivy: \(.packages.only_trivy | join(","))" end),
  "   findings   \(.counts.findings): both \(.counts.both), grype only \(.counts.only_grype), trivy only \(.counts.only_trivy)",
  "   grype      \(.counts.grype | sevs)",
  "   trivy      \(.counts.trivy | sevs)",
  "   disagree   \(.counts.severity_disagrees) on severity" ,
  (.findings[] | select(.severity_disagrees) | "                \(.id) \(.package): grype \(.grype.severity) / trivy \(.trivy.severity)"),
  "   fixable    \(.counts.fixable)",
  (.findings[] | select(.fixable) | "                \(.id) \(.package) \(.installed) -> \(((.grype.fixed_in // []) + (.trivy.fixed_in // [])) | unique | join(","))")
' "${REPORT}"
echo "   report     ${REPORT}"
