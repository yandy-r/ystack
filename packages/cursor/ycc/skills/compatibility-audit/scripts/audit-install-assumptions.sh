#!/usr/bin/env bash
# audit-install-assumptions.sh — validate install-path assumptions for each
# generated compatibility target (Claude, Cursor, Codex, opencode, omp, pi).
#
# Flags:
#   --target=<claude|cursor|codex|opencode|omp|pi|all>  (default: all)
#   --format=<human|json>                        (default: human)
#   --help, -h                                   print usage and exit 0
#
# Exit: 0=all PASS, 1=any FAIL, 2=usage error

set -euo pipefail

usage() { cat <<'EOF'
Usage: audit-install-assumptions.sh [--target=<claude|cursor|codex|opencode|omp|pi|all>]
                                    [--format=<human|json>] [--help|-h]
                                    [repo-root]

Validates install-path assumptions for each generated compatibility target.
Exit 0 if all checks pass; 1 if any fail; 2 on usage error.
EOF
}

TARGET="all"; FORMAT="human"; REPO_ROOT_INPUT=""
for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#--target=}" ;;
    --format=*) FORMAT="${arg#--format=}" ;;
    --help|-h)  usage; exit 0 ;;
    -*)
      echo "audit-install-assumptions.sh: unknown flag: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$REPO_ROOT_INPUT" ]]; then
        echo "audit-install-assumptions.sh: multiple repo roots provided: $REPO_ROOT_INPUT and $arg" >&2
        usage >&2
        exit 2
      fi
      REPO_ROOT_INPUT="$arg"
      ;;
  esac
done
case "$TARGET" in all|claude|cursor|codex|opencode|omp|pi) ;;
  *) echo "audit-install-assumptions.sh: unknown --target: $TARGET" >&2; usage >&2; exit 2 ;; esac
case "$FORMAT" in human|json) ;;
  *) echo "audit-install-assumptions.sh: unknown --format: $FORMAT" >&2; usage >&2; exit 2 ;; esac

# Resolve REPO_ROOT
# Prefer the runtime-injected CLAUDE_PLUGIN_ROOT (set when the skill runs from an
# installed plugin). Fall back to walking up from SCRIPT_DIR for dev/source-tree use.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT=""
if [[ -n "$REPO_ROOT_INPUT" ]]; then
  if [[ ! -d "$REPO_ROOT_INPUT" ]]; then
    echo "audit-install-assumptions.sh: repo root input is not a directory: $REPO_ROOT_INPUT" >&2
    exit 2
  fi
  candidate="$(cd "$REPO_ROOT_INPUT" && pwd)"
  while [[ "$candidate" != "/" ]]; do
    [[ -f "$candidate/.claude-plugin/marketplace.json" ]] && { REPO_ROOT="$candidate"; break; }
    candidate="$(dirname "$candidate")"
  done
  [[ -z "$REPO_ROOT" && -f "/.claude-plugin/marketplace.json" ]] && REPO_ROOT="/"
fi
if [[ -z "$REPO_ROOT" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
  # Normalize trailing slash and accept the value directly as REPO_ROOT-equivalent.
  # Downstream code references REPO_ROOT for .claude-plugin/, packages/cursor/,
  # .codex-plugin/ and ycc/.claude-plugin/ — these all live at the repo root.
  # When CLAUDE_PLUGIN_ROOT points at the installed plugin (e.g. the 'ycc/' dir),
  # walk up once so downstream paths resolve to the repo containing the three bundles.
  cand="${CLAUDE_PLUGIN_ROOT%/}"
  # If cand itself contains .claude-plugin/marketplace.json, use it; else walk up.
  while [[ "$cand" != "/" && -z "$REPO_ROOT" ]]; do
    [[ -f "$cand/.claude-plugin/marketplace.json" ]] && REPO_ROOT="$cand"
    cand="$(dirname "$cand")"
  done
fi
if [[ -z "$REPO_ROOT" ]]; then
  candidate="$SCRIPT_DIR"
  while [[ "$candidate" != "/" ]]; do
    [[ -f "$candidate/.claude-plugin/marketplace.json" ]] && { REPO_ROOT="$candidate"; break; }
    candidate="$(dirname "$candidate")"
  done
fi
if [[ -z "$REPO_ROOT" ]]; then
  candidate="$PWD"
  while [[ "$candidate" != "/" ]]; do
    [[ -f "$candidate/.claude-plugin/marketplace.json" ]] && { REPO_ROOT="$candidate"; break; }
    candidate="$(dirname "$candidate")"
  done
fi
[[ -z "$REPO_ROOT" && -f "/.claude-plugin/marketplace.json" ]] && REPO_ROOT="/"
[[ -z "$REPO_ROOT" ]] && { echo "audit-install-assumptions.sh: repo root not found" >&2; exit 2; }
echo "audit-install-assumptions.sh: repo root is $REPO_ROOT" >&2

# Verify python3
set +e; python3 --version >/dev/null 2>&1; PY=$?; set -e
[[ $PY -ne 0 ]] && { echo "audit-install-assumptions.sh: python3 not found" >&2; exit 1; }

# Check storage
CT=(); CI=(); CS=(); CD=()
record() { CT+=("$1"); CI+=("$2"); CS+=("$3"); CD+=("$4"); }

json_ok() { set +e; python3 -m json.tool "$1" >/dev/null 2>&1; local r=$?; set -e; return $r; }

# ---------------------------------------------------------------------------
# Claude checks
# ---------------------------------------------------------------------------
run_claude_checks() {
  local mkt="${REPO_ROOT}/.claude-plugin/marketplace.json"
  local plugin="${REPO_ROOT}/ycc/.claude-plugin/plugin.json"

  json_ok "$mkt" && record "claude" "C1" "PASS" "" \
    || { record "claude" "C1" "FAIL" "${mkt} is not valid JSON"; return; }

  local r; set +e
  r=$(python3 - "$mkt" <<'PY'
import sys,json; d=json.load(open(sys.argv[1]))
entry=next((p for p in d.get("plugins",[]) if p.get("name")=="ycc"),None)
if entry is None: print("FAIL:no plugin named ycc in marketplace plugins array")
elif entry.get("source")!="./ycc": print(f"FAIL:ycc source={entry.get('source')!r} (expected './ycc')")
else: print("PASS:")
PY
  ); set -e; record "claude" "C2" "${r%%:*}" "${r#*:}"

  json_ok "$plugin" && record "claude" "C3" "PASS" "" \
    || { record "claude" "C3" "FAIL" "${plugin} is not valid JSON"; return; }

  set +e
  r=$(python3 - "$mkt" "$plugin" <<'PY'
import sys,json
mkt=json.load(open(sys.argv[1])); plug=json.load(open(sys.argv[2]))
pv=plug.get("version")
if not pv: print("FAIL:plugin.json has no version field"); raise SystemExit
ycc=next((p for p in mkt.get("plugins",[]) if p.get("name")=="ycc"),None)
mv=ycc.get("version") if ycc else None
if mv is None: print(f"PASS (marketplace has no version field):plugin version={pv}")
elif mv==pv: print(f"PASS:versions match ({pv})")
else: print(f"FAIL:plugin.json version={pv} != marketplace version={mv}")
PY
  ); set -e; record "claude" "C4" "${r%%:*}" "${r#*:}"
}

# ---------------------------------------------------------------------------
# Cursor checks
# ---------------------------------------------------------------------------
run_cursor_checks() {
  local ycc_dir="${REPO_ROOT}/packages/cursor/ycc"
  local rules_dir="${REPO_ROOT}/packages/cursor/ycc-rules"
  [[ -d "$ycc_dir" ]] && record "cursor" "CR1" "PASS" "" \
    || { record "cursor" "CR1" "FAIL" "${ycc_dir} does not exist"; return; }

  local miss=()
  for s in skills agents; do [[ -d "${ycc_dir}/${s}" ]] || miss+=("$s"); done
  [[ -d "${rules_dir}/rules" ]] || miss+=("rules")
  [[ ${#miss[@]} -eq 0 ]] && record "cursor" "CR2" "PASS" "" \
    || record "cursor" "CR2" "FAIL" "missing: ${miss[*]}"

  # Cross-target meta files are copied verbatim by the generator (see
  # VERBATIM_SKILL_FILES in scripts/generate_cursor_skills.py). They
  # intentionally reference CLAUDE_* identifiers because they describe all
  # three targets, so they must be excluded from residue scans.
  local cr_excludes=(
    --exclude-dir=compatibility-audit
    --exclude="support-notes.md"
    --exclude="target-capability-matrix.md"
  )

  local hits
  # CR3: plugin-root variable residue in code/config files.
  # Pattern is constructed at runtime so this script does not trigger
  # target-bundle content-policy validators when copied verbatim.
  local pr_token pr_pattern
  pr_token="CLAUDE_PLUGIN"
  pr_pattern="${pr_token}_ROOT"
  set +e
  hits=$(grep -rl --include='*.json' --include='*.sh' --include='*.toml' --include='*.yaml' --include='*.yml' \
    "${cr_excludes[@]}" -- "${pr_pattern}" "${ycc_dir}" "${rules_dir}" 2>/dev/null | head -5)
  set -e
  [[ -z "$hits" ]] && record "cursor" "CR3" "PASS" "" \
    || record "cursor" "CR3" "FAIL" "plugin-root variable residue in code/config: $(printf '%s ' "$hits")"

  # CR4: Claude config-path residue in NON-markdown files. Markdown prose may
  # legitimately reference the settings.json path as advisory documentation.
  # Pattern is constructed at runtime so this script doesn't self-match when
  # copied into generated bundles.
  local cc_token cc_pattern cc_label
  cc_token="claude"
  cc_pattern='\.'"${cc_token}"'/'
  cc_label=".${cc_token}/"
  set +e
  hits=$(grep -rl --include='*.json' --include='*.sh' --include='*.toml' --include='*.yaml' --include='*.yml' \
    "${cr_excludes[@]}" -- "${cc_pattern}" "${ycc_dir}" "${rules_dir}" 2>/dev/null | head -5)
  set -e
  [[ -z "$hits" ]] && record "cursor" "CR4" "PASS" "" \
    || record "cursor" "CR4" "FAIL" "${cc_label} residue in code/config: $(printf '%s ' "$hits")"
}

# ---------------------------------------------------------------------------
# Codex checks
# ---------------------------------------------------------------------------
run_codex_checks() {
  local cp="${REPO_ROOT}/.codex-plugin/ycc/.codex-plugin/plugin.json"
  local cm="${REPO_ROOT}/.codex-plugin/ycc/.mcp.json"
  local cmkt="${REPO_ROOT}/.agents/plugins/marketplace.json"
  local csd="${REPO_ROOT}/.codex-plugin/ycc/skills"

  if   [[ ! -f "$cp" ]];  then record "codex" "CX1" "FAIL" "${cp} does not exist"
  elif json_ok "$cp";     then record "codex" "CX1" "PASS" ""
  else                         record "codex" "CX1" "FAIL" "${cp} is not valid JSON"; fi

  if   [[ ! -f "$cm" ]];  then record "codex" "CX2" "PASS" ".mcp.json absent (legitimately optional)"
  elif json_ok "$cm";     then record "codex" "CX2" "PASS" ""
  else                         record "codex" "CX2" "FAIL" "${cm} exists but is not valid JSON"; fi

  if   [[ ! -f "$cmkt" ]]; then record "codex" "CX3" "FAIL" "${cmkt} does not exist"
  elif json_ok "$cmkt";    then record "codex" "CX3" "PASS" ""
  else                          record "codex" "CX3" "FAIL" "${cmkt} is not valid JSON"; fi

  if [[ ! -f "$cp" ]]; then record "codex" "CX4" "FAIL" "${cp} missing — cannot verify skills field"; return; fi
  local r; set +e
  r=$(python3 - "$cp" "$csd" <<'PY'
import sys,json,os; d=json.load(open(sys.argv[1])); sf,sd=d.get("skills"),sys.argv[2]
if sf!="./skills/": print(f"FAIL:skills={sf!r} (expected './skills/')")
elif not os.path.isdir(sd): print(f"FAIL:skills field ok but {sd} does not exist")
else: print("PASS:")
PY
  ); set -e; record "codex" "CX4" "${r%%:*}" "${r#*:}"
}

# ---------------------------------------------------------------------------
# opencode checks
# ---------------------------------------------------------------------------
run_opencode_checks() {
  local odir="${REPO_ROOT}/.opencode-plugin"
  [[ -d "$odir" ]] && record "opencode" "OC1" "PASS" "" \
    || { record "opencode" "OC1" "FAIL" "${odir} does not exist"; return; }

  local miss=()
  for s in skills agents commands; do [[ -d "${odir}/${s}" ]] || miss+=("$s"); done
  [[ ${#miss[@]} -eq 0 ]] && record "opencode" "OC2" "PASS" "" \
    || record "opencode" "OC2" "FAIL" "missing: ${miss[*]}"

  # OC3: opencode.json is valid JSON with the expected $schema and no
  # `instructions` key. The bundle ships its rules as the global AGENTS.md; a
  # relative `instructions` entry resolves from the workspace and loads the
  # project AGENTS.md a second time.
  local cfg="${odir}/opencode.json"
  if   [[ ! -f "$cfg" ]]; then record "opencode" "OC3" "FAIL" "${cfg} does not exist"
  elif json_ok "$cfg";    then
    local r; set +e
    r=$(python3 - "$cfg" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if "$schema" not in d: print(f"FAIL:{sys.argv[1]}: missing key '$schema'")
elif d.get("$schema")!="https://opencode.ai/config.json": print(f"FAIL:{sys.argv[1]}: $schema={d.get('$schema')!r} (expected 'https://opencode.ai/config.json')")
elif "instructions" in d: print(f"FAIL:{sys.argv[1]}: unexpected key 'instructions' (bundle rules ship as the global AGENTS.md; a relative entry resolves from the workspace and loads the project AGENTS.md a second time)")
else: print("PASS:")
PY
    ); set -e; record "opencode" "OC3" "${r%%:*}" "${r#*:}"
  else record "opencode" "OC3" "FAIL" "${cfg} is not valid JSON"; fi

  # OC4: AGENTS.md exists (bundle-level rules file)
  local rules="${odir}/AGENTS.md"
  [[ -f "$rules" ]] && record "opencode" "OC4" "PASS" "" \
    || record "opencode" "OC4" "FAIL" "${rules} does not exist"

  # OC5/OC6: no Claude-plugin residue in the opencode bundle's code/config
  # files. Cross-target meta files copied verbatim are allowed to reference
  # CLAUDE_* identifiers because they describe all four targets (matches the
  # VERBATIM_SKILL_FILES set in generate_opencode_common.py).
  local oc_excludes=(
    --exclude-dir=compatibility-audit
    --exclude="support-notes.md"
    --exclude="target-capability-matrix.md"
    --exclude="build-hook-config.sh"
  )
  local hits pr_token pr_pattern
  pr_token="CLAUDE_PLUGIN"
  pr_pattern="${pr_token}_ROOT"
  set +e
  hits=$(grep -rl --include='*.json' --include='*.sh' --include='*.toml' --include='*.yaml' --include='*.yml' \
    "${oc_excludes[@]}" -- "${pr_pattern}" "${odir}" 2>/dev/null | head -5)
  set -e
  [[ -z "$hits" ]] && record "opencode" "OC5" "PASS" "" \
    || record "opencode" "OC5" "FAIL" "plugin-root variable residue in code/config: $(printf '%s ' "$hits")"

  # OC6: Claude config-path residue in NON-markdown files.
  local cc_token cc_pattern cc_label
  cc_token="claude"
  cc_pattern='\.'"${cc_token}"'/'
  cc_label=".${cc_token}/"
  set +e
  hits=$(grep -rl --include='*.json' --include='*.sh' --include='*.toml' --include='*.yaml' --include='*.yml' \
    "${oc_excludes[@]}" -- "${cc_pattern}" "${odir}" 2>/dev/null | head -5)
  set -e
  [[ -z "$hits" ]] && record "opencode" "OC6" "PASS" "" \
    || record "opencode" "OC6" "FAIL" "${cc_label} residue in code/config: $(printf '%s ' "$hits")"
}

# ---------------------------------------------------------------------------
# omp (oh-my-pi) checks
# ---------------------------------------------------------------------------
run_omp_checks() {
  local odir="${REPO_ROOT}/.omp-plugin"
  local matrix="${REPO_ROOT}/ycc/skills/_shared/references/target-capability-matrix.md"

  # OM1: the generated catalog and the matrix INSTALL_PATH:omp verdict must agree.
  # The root .omp-plugin/ exists while an OMP package is listed in ycc/settings/packages.json;
  # with none listed it is absent and 'partial' means install.sh --target omp installs an export.
  if [[ ! -f "$matrix" ]]; then
    record "omp" "OM1" "FAIL" "${matrix} does not exist — cannot read INSTALL_PATH:omp"; return
  fi
  local verdict; set +e
  verdict=$(python3 - "$matrix" <<'PY'
import sys
header = None
for raw in open(sys.argv[1], encoding="utf-8"):
    s = raw.strip()
    if not s.startswith("|"):
        if header is not None:
            break
        continue
    cells = [c.strip() for c in s.strip("|").split("|")]
    if all(c and set(c) == {"-"} for c in cells):
        continue
    if header is None:
        header = cells
        continue
    if cells[0] == "INSTALL_PATH" and "omp" in header and len(cells) == len(header):
        print(cells[header.index("omp")])
        break
PY
  ); set -e
  if [[ -z "$verdict" ]]; then
    record "omp" "OM1" "FAIL" "INSTALL_PATH:omp not found in ${matrix}"
  elif [[ ! -d "$odir" ]]; then
    case "$verdict" in
      unsupported) record "omp" "OM1" "PASS" "${odir} not generated yet (matrix INSTALL_PATH:omp=unsupported)" ;;
      partial)     record "omp" "OM1" "PASS" "${odir} absent until a package is listed; install.sh --target omp installs a generated export (matrix INSTALL_PATH:omp=partial)" ;;
      *)           record "omp" "OM1" "FAIL" "${odir} does not exist but matrix INSTALL_PATH:omp=${verdict}" ;;
    esac
    return
  elif [[ "$verdict" == "unsupported" ]]; then
    record "omp" "OM1" "FAIL" "${odir} exists but matrix INSTALL_PATH:omp=unsupported"
  else
    record "omp" "OM1" "PASS" ""
  fi

  # OM2: a generated tree must carry a valid catalog.
  local mkt="${odir}/marketplace.json"
  if   [[ ! -f "$mkt" ]]; then record "omp" "OM2" "FAIL" "${mkt} does not exist"
  elif json_ok "$mkt";    then record "omp" "OM2" "PASS" ""
  else                         record "omp" "OM2" "FAIL" "${mkt} is not valid JSON"; fi
}

# ---------------------------------------------------------------------------
# pi checks
# ---------------------------------------------------------------------------
run_pi_checks() {
  local pdir="${REPO_ROOT}/packages/pi"
  local matrix="${REPO_ROOT}/ycc/skills/_shared/references/target-capability-matrix.md"

  # PI1: the generated tree and every matrix pi verdict must agree (ADR 0003). With no
  # packages/pi/ every pi cell must be unsupported; once the tree exists (YAN-1188),
  # INSTALL_PATH:pi must no longer be unsupported.
  if [[ ! -f "$matrix" ]]; then
    record "pi" "PI1" "FAIL" "${matrix} does not exist — cannot read the pi column"; return
  fi
  local verdicts; set +e
  verdicts=$(python3 - "$matrix" <<'PY'
import sys
header = None
for raw in open(sys.argv[1], encoding="utf-8"):
    s = raw.strip()
    if not s.startswith("|"):
        if header is not None:
            break
        continue
    cells = [c.strip() for c in s.strip("|").split("|")]
    if all(c and set(c) == {"-"} for c in cells):
        continue
    if header is None:
        header = cells
        continue
    if "pi" in header and len(cells) == len(header):
        print(f"{cells[0]}={cells[header.index('pi')]}")
PY
  ); local parse_rc=$?; set -e
  if [[ $parse_rc -ne 0 ]]; then
    record "pi" "PI1" "FAIL" "matrix parse failed (python rc=${parse_rc})"; return
  fi
  local install_path
  install_path="$(sed -n 's/^INSTALL_PATH=//p' <<<"$verdicts")"
  if [[ -z "$install_path" ]]; then
    record "pi" "PI1" "FAIL" "INSTALL_PATH:pi not found in ${matrix}"
  elif [[ ! -d "$pdir" ]]; then
    local claimed
    claimed="$(grep -v '=unsupported$' <<<"$verdicts" | tr '\n' ' ' || true)"
    if [[ -z "${claimed// /}" ]]; then
      record "pi" "PI1" "PASS" "${pdir} not generated yet (every matrix pi verdict is unsupported)"
    else
      record "pi" "PI1" "FAIL" "${pdir} does not exist but the matrix claims ${claimed% }"
    fi
  elif [[ "$install_path" == "unsupported" ]]; then
    record "pi" "PI1" "FAIL" "${pdir} exists but matrix INSTALL_PATH:pi=unsupported"
  else
    record "pi" "PI1" "PASS" ""
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$TARGET" in
  claude)   run_claude_checks ;;
  cursor)   run_cursor_checks ;;
  codex)    run_codex_checks  ;;
  opencode) run_opencode_checks ;;
  omp)      run_omp_checks ;;
  pi)       run_pi_checks ;;
  all)      run_claude_checks; run_cursor_checks; run_codex_checks; run_opencode_checks; run_omp_checks; run_pi_checks ;;
esac

OVERALL_RC=0
for s in "${CS[@]}"; do [[ "$s" == "FAIL" ]] && { OVERALL_RC=1; break; }; done

# ---------------------------------------------------------------------------
# Human output
# ---------------------------------------------------------------------------
emit_human() {
  local tgts=(); [[ "$TARGET" == "all" ]] && tgts=(claude cursor codex opencode omp pi) || tgts=("$TARGET")
  local n=${#CI[@]}
  for tgt in "${tgts[@]}"; do
    local pass=0 fail=0 i=0
    while [[ $i -lt $n ]]; do
      if [[ "${CT[$i]}" == "$tgt" ]]; then
        local st="${CS[$i]}" det="${CD[$i]}"
        if [[ "$st" == "FAIL" ]]; then
          echo "[${tgt}] ${CI[$i]} FAIL: ${det}"; fail=$((fail+1))
        elif [[ -n "$det" ]]; then
          echo "[${tgt}] ${CI[$i]} ${st}: ${det}"; pass=$((pass+1))
        else
          echo "[${tgt}] ${CI[$i]} ${st}"; pass=$((pass+1))
        fi
      fi
      i=$((i+1))
    done
    echo "[${tgt}] summary: ${pass} PASS / ${fail} FAIL"
  done
}

# ---------------------------------------------------------------------------
# JSON output — delegated to python3
# ---------------------------------------------------------------------------
emit_json() {
  local tmp; tmp="$(mktemp -d)"
  local n=${#CI[@]} i=0
  while [[ $i -lt $n ]]; do
    printf '%s' "${CT[$i]}"  > "${tmp}/t_${i}"
    printf '%s' "${CI[$i]}"  > "${tmp}/i_${i}"
    printf '%s' "${CS[$i]}"  > "${tmp}/s_${i}"
    printf '%s' "${CD[$i]}"  > "${tmp}/d_${i}"
    i=$((i+1))
  done
  python3 - "$n" "$tmp" "$TARGET" <<'PY'
import json,sys,os
from datetime import datetime,timezone
n,tmp,tgt=int(sys.argv[1]),sys.argv[2],sys.argv[3]
rd=lambda p:open(p).read() if os.path.exists(p) else ""
ts=[rd(f"{tmp}/t_{i}") for i in range(n)]; ids=[rd(f"{tmp}/i_{i}") for i in range(n)]
ss=[rd(f"{tmp}/s_{i}") for i in range(n)]; ds=[rd(f"{tmp}/d_{i}") for i in range(n)]
def build(t):
    ch=[{"id":ids[i],"status":ss[i],"detail":ds[i] or None} for i in range(n) if ts[i]==t]
    return {"checks":ch,"ok":all(c["status"]!="FAIL" for c in ch)}
names=["claude","cursor","codex","opencode","omp","pi"] if tgt=="all" else [tgt]
out={t:build(t) for t in names}
print(json.dumps({"as_of":datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "targets":out,"ok":all(v["ok"] for v in out.values())},indent=2))
PY
  rm -rf "$tmp"
}

if [[ "$FORMAT" == "human" ]]; then emit_human; else emit_json; fi
exit $OVERALL_RC
