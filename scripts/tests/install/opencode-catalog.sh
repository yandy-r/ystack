#!/usr/bin/env bash
# install.sh tests — opencode third-party plugin catalog
# (ycc/settings/opencode-plugins.json): opt-in sync, idempotence, companion
# ownership, byte-identical remove, --purge-cache and --project.
#
# Runs alone (bash scripts/tests/install/opencode-catalog.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLIM=oh-my-opencode-slim
SLIM_PKG="${SLIM}@3.0.5"
SLIM_COMPANION_SRC="${REPO_ROOT}/ycc/settings/opencode-plugins/${SLIM}.json"

# catalog_seed <opencode.json> — a user config in the formatting the merge
# helper writes (json.dumps indent=2 + newline), so remove can be checked
# byte-for-byte against it.
catalog_seed() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' '{
  "model": "9router/Frontier",
  "plugins": [
    "@user/local-plugin"
  ]
}' > "$1"
}

# json_query <file> <python expr over `d`> — print the expression's value.
json_query() {
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

catalog_tree_digest() {
    (cd "$1" && find . -path ./claude-calls.log -prune -o \( -type f -o -type l \) -print0 \
	| sort -z | xargs -0r sha256sum)
}

catalog_assert_unchanged() {
    local label="$1"
    if [[ "$(catalog_tree_digest "${home}")" == "${before}" ]]; then
        ok "${label}"
    else
        ko "${label}" "$(diff <(echo "${before}") <(catalog_tree_digest "${home}"))"
    fi
}

home="$(new_home)"
install_must_succeed "${home}" list plugins --target opencode
assert_contains $'\n'"${INSTALL_OUT}"$'\n' $'\n'"${SLIM}"$'\n' "list plugins --target opencode lists the catalog name"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "./ycc-sensitive-guard" "default --intent plugins merges the bundle plugins"
assert_not_contains "${merged}" "${SLIM}" "default --intent plugins does not install a catalog plugin"
if [[ ! -e "${home}/.config/opencode/${SLIM}.json" ]]; then ok "default run ships no catalog companion"; else ko "default run ships no catalog companion"; fi

echo "== opencode catalog: dry-run settings =="

home="$(new_home)"
catalog_seed "${home}/.config/opencode/opencode.json"
before="$(catalog_tree_digest "${home}")"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --dry-run --global
assert_contains "${INSTALL_OUT}" "would set /plugins" "catalog sync dry-run previews the managed plugin entry"
assert_contains "${INSTALL_OUT}" "would copy ${home}/.config/opencode/${SLIM}.json" "catalog sync dry-run previews the companion copy"
assert_not_contains "${INSTALL_OUT}" "step has no preview" "catalog settings are previewable"
catalog_assert_unchanged "catalog sync dry-run changes no HOME config, companion or state bytes"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
mkdir -p "${home}/.cache/opencode/npm/${SLIM_PKG}/1/node_modules/${SLIM}"
before="$(catalog_tree_digest "${home}")"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --purge-cache --dry-run --global
assert_contains "${INSTALL_OUT}" "would remove /plugins" "catalog remove dry-run previews the managed plugin removal"
assert_contains "${INSTALL_OUT}" "would remove ${home}/.config/opencode/${SLIM}.json" "catalog remove dry-run uses the projected config to preview companion removal"
assert_contains "${INSTALL_OUT}" "would remove ${home}/.cache/opencode/npm/${SLIM_PKG}" "catalog remove dry-run previews cache removal after the projected plugin removal"

catalog_assert_unchanged "catalog remove dry-run changes no HOME config, companion, cache or state bytes"

home="$(new_home)"
mkdir -p "${home}/.config/opencode"
printf '{"plugins": ["%s"]}\n' "${SLIM_PKG}" > "${home}/.config/opencode/opencode.json"
cp "${SLIM_COMPANION_SRC}" "${home}/.config/opencode/${SLIM}.json"
mkdir -p "${home}/.cache/opencode/npm/${SLIM_PKG}"
before="$(catalog_tree_digest "${home}")"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --purge-cache --dry-run --global
assert_contains "${INSTALL_OUT}" "would still load it" "catalog remove dry-run preserves companions for a locally owned plugin"
assert_not_contains "${INSTALL_OUT}" "would remove ${home}/.config/opencode/${SLIM}.json" "catalog remove dry-run does not authorize local companion removal"
assert_not_contains "${INSTALL_OUT}" "would remove ${home}/.cache/opencode/npm/${SLIM_PKG}" "catalog remove dry-run does not authorize local cache removal"
catalog_assert_unchanged "catalog local-edit dry-run changes no HOME bytes"

echo "== opencode catalog: sync --plugins ${SLIM} =="

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
companion="${home}/.config/opencode/${SLIM}.json"
catalog_seed "${cfg}"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
out="${INSTALL_OUT}"
assert_contains "$(json_query "${cfg}" 'd["plugins"]')" "'${SLIM_PKG}'" "catalog sync adds the pinned plugins item"
assert_contains "$(json_query "${cfg}" 'd["plugins"]')" "'@user/local-plugin'" "catalog sync keeps the user plugin"
assert_not_contains "$(json_query "${cfg}" 'd["plugins"]')" "ycc-sensitive-guard" "a catalog-only selection leaves the bundle plugins alone"
assert_contains "$(json_query "${cfg}" '[d["agents"][a]["disabled"] for a in ("explore", "general")]')" "[True, True]" "catalog sync sets agents.{explore,general}.disabled"
if cmp -s "${SLIM_COMPANION_SRC}" "${companion}"; then ok "catalog sync ships the companion config"; else ko "catalog sync ships the companion config"; fi
assert_contains "${out}" "OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true" "catalog sync prints the shell-rc note"
assert_contains "${out}" '"lsp": true' "catalog sync prints the lsp note"
assert_not_contains "${out}" "none of the selected plugins" "a catalog-only selection does not warn about the bundle group"
if [[ ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "a catalog-only selection ships no guard dir"; else ko "a catalog-only selection ships no guard dir"; fi

cp "${cfg}" "${home}/first.json"
cp "${companion}" "${home}/first-companion.json"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
if cmp -s "${home}/first.json" "${cfg}" && cmp -s "${home}/first-companion.json" "${companion}"; then
    ok "a second catalog sync is a byte-identical no-op"
else
    ko "a second catalog sync is a byte-identical no-op" "$(diff "${home}/first.json" "${cfg}")"
fi

printf '{"preset": "mine"}\n' > "${companion}"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
assert_contains "${INSTALL_OUT}" "kept ${companion}: local edits" "catalog sync warns about a user-edited companion"
assert_contains "$(cat "${companion}")" '"mine"' "catalog sync keeps a user-edited companion"

# --force: sync replaces a user-edited companion; --force --dry-run previews
# the replacement without touching it.
printf '{"preset": "mine"}\n' > "${companion}"
before="$(catalog_tree_digest "${home}")"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --force --dry-run --global
assert_contains "${INSTALL_OUT}" "would copy ${companion}" "catalog sync --force --dry-run previews replacing a user-edited companion"
assert_not_contains "${INSTALL_OUT}" "kept ${companion}" "catalog sync --force --dry-run does not report the edited companion as kept"
catalog_assert_unchanged "catalog sync --force --dry-run leaves the edited companion bytes unchanged"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --force --global
if cmp -s "${SLIM_COMPANION_SRC}" "${companion}"; then ok "catalog sync --force replaces a user-edited companion"; else ko "catalog sync --force replaces a user-edited companion" "$(cat "${companion}")"; fi

echo "== opencode catalog: mixed bundle + catalog selection =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "./ycc-sensitive-guard,${SLIM}" --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "./ycc-sensitive-guard" "a mixed selection merges the bundle item"
assert_contains "${merged}" "${SLIM_PKG}" "a mixed selection merges the catalog item"
assert_not_contains "${merged}" "@prevalentware/opencode-goal-plugin" "a mixed selection skips the unselected bundle item"
if [[ -f "${home}/.config/opencode/ycc-sensitive-guard/index.js" ]]; then ok "a mixed selection ships the guard dir"; else ko "a mixed selection ships the guard dir"; fi
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_not_contains "${merged}" "${SLIM}" "remove --plugins <catalog> takes the catalog item"
assert_contains "${merged}" "./ycc-sensitive-guard" "remove --plugins <catalog> keeps the bundle item"
if [[ -d "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "remove --plugins <catalog> keeps the guard dir"; else ko "remove --plugins <catalog> keeps the guard dir"; fi

echo "== opencode catalog: remove =="

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
companion="${home}/.config/opencode/${SLIM}.json"
catalog_seed "${cfg}"
cp "${cfg}" "${home}/seed.json"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --global
if cmp -s "${home}/seed.json" "${cfg}"; then ok "catalog remove restores opencode.json byte-identical to the seed"; else ko "catalog remove restores opencode.json byte-identical to the seed" "$(diff "${home}/seed.json" "${cfg}")"; fi
if [[ ! -e "${companion}" ]]; then ok "catalog remove deletes the companion"; else ko "catalog remove deletes the companion"; fi
assert_contains "${INSTALL_OUT}" "you may delete these lines from your shell rc" "catalog remove prints the rc cleanup note"

# remove --intent plugins without --plugins takes back every catalog plugin
# ycc installed, and the bundle items; a home without one is a quiet no-op.
home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
catalog_seed "${cfg}"
cp "${cfg}" "${home}/seed.json"
install_must_succeed "${home}" sync --target opencode --intent plugins --global
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
install_must_succeed "${home}" remove --target opencode --intent plugins --global
if cmp -s "${home}/seed.json" "${cfg}"; then ok "remove --intent plugins takes back bundle and catalog items"; else ko "remove --intent plugins takes back bundle and catalog items" "$(diff "${home}/seed.json" "${cfg}")"; fi
if [[ ! -e "${home}/.config/opencode/${SLIM}.json" ]]; then ok "remove --intent plugins deletes the catalog companion"; else ko "remove --intent plugins deletes the catalog companion"; fi

home="$(new_home)"
catalog_seed "${home}/.config/opencode/opencode.json"
install_must_succeed "${home}" sync --target opencode --intent plugins --global
install_must_succeed "${home}" remove --target opencode --intent plugins --global
assert_not_contains "${INSTALL_OUT}" "you may delete these lines" "remove of a never-installed catalog plugin prints no notes"

# A user-written slim entry is the user's: remove keeps it and its cache.
home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{"plugins": ["%s"]}\n' "${SLIM_PKG}" > "${cfg}"
mkdir -p "${home}/.cache/opencode/npm/${SLIM_PKG}/1/node_modules/${SLIM}"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --purge-cache --global
assert_contains "$(cat "${cfg}")" "${SLIM_PKG}" "remove keeps a user-written catalog item"
if [[ -d "${home}/.cache/opencode/npm/${SLIM_PKG}" ]]; then ok "--purge-cache keeps the cache a kept item still loads"; else ko "--purge-cache keeps the cache a kept item still loads"; fi

# A JSONC opencode.json is read as opencode reads it: the user's item still
# loads the plugin, so --purge-cache keeps its cache.
home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
mkdir -p "$(dirname "${cfg}")"
printf '{\n  // mine\n  "plugins": ["%s",],\n}\n' "${SLIM_PKG}" > "${cfg}"
mkdir -p "${home}/.cache/opencode/npm/${SLIM_PKG}/1/node_modules/${SLIM}"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --purge-cache --global
assert_contains "$(cat "${cfg}")" "${SLIM_PKG}" "remove keeps a user-written catalog item in a JSONC opencode.json"
if [[ -d "${home}/.cache/opencode/npm/${SLIM_PKG}" ]]; then ok "--purge-cache keeps the cache a JSONC config still loads"; else ko "--purge-cache keeps the cache a JSONC config still loads"; fi

# slim's own installer: a user-written item and a companion identical to ycc's
# copy, with no ycc state. Remove keeps both.
home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
companion="${home}/.config/opencode/${SLIM}.json"
mkdir -p "$(dirname "${cfg}")"
printf '{"plugins": ["%s"]}\n' "${SLIM_PKG}" > "${cfg}"
cp "${SLIM_COMPANION_SRC}" "${companion}"
install_must_succeed "${home}" remove --target opencode --intent plugins --global
if cmp -s "${SLIM_COMPANION_SRC}" "${companion}"; then ok "remove keeps a companion ycc never installed"; else ko "remove keeps a companion ycc never installed"; fi
assert_contains "$(cat "${cfg}")" "${SLIM_PKG}" "remove keeps the user-written item beside that companion"

# The user's own slim setup, with the agents keys slim needs beside the bundle:
# remove without --plugins never strips values ycc did not record writing.
home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
mkdir -p "$(dirname "${cfg}")"
printf '{"plugins": ["%s"], "agents": {"general": {"disabled": true}, "explore": {"disabled": true}}}\n' "${SLIM_PKG}" > "${cfg}"
install_must_succeed "${home}" remove --target opencode --intent plugins --global
assert_contains "$(json_query "${cfg}" '[d["agents"][a].get("disabled") for a in ("explore", "general")]')" "[True, True]" "remove without --plugins keeps agents keys ycc never wrote"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --global
assert_contains "$(json_query "${cfg}" '[d["agents"][a].get("disabled") for a in ("explore", "general")]')" "[True, True]" "remove --plugins keeps agents keys ycc never wrote"

echo "== opencode catalog: shared agents entries with the bundle settings =="

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
install_must_succeed "${home}" sync --target opencode --intent settings,plugins --global
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
assert_contains "$(json_query "${cfg}" '[sorted(d["agents"][a]) for a in ("explore", "general")]')" "[['disabled', 'model'], ['disabled', 'model']]" "catalog sync adds disabled beside the bundle model"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --global
assert_not_contains "${INSTALL_OUT}" "kept your local value" "catalog remove owns only its agents leaves"
assert_contains "$(json_query "${cfg}" '[sorted(d["agents"][a]) for a in ("explore", "general")]')" "[['model'], ['model']]" "catalog remove keeps the bundle model and drops disabled"
install_must_succeed "${home}" remove --target opencode --intent settings,plugins --global
assert_not_contains "${INSTALL_OUT}" "kept your local value" "bundle remove after a catalog remove has no conflicts"
if [[ ! -e "${cfg}" ]] || ! grep -q '"agents"' "${cfg}"; then ok "bundle remove takes the agents back"; else ko "bundle remove takes the agents back" "$(cat "${cfg}")"; fi

# One full uninstall with both installed: no conflicts and nothing left behind.
home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
install_must_succeed "${home}" sync --target opencode --intent settings,plugins --global
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
install_must_succeed "${home}" remove --target opencode --intent settings,plugins --global
assert_not_contains "${INSTALL_OUT}" "kept your local value" "one remove of bundle + catalog has no conflicts"
if [[ ! -e "${cfg}" ]] || ! grep -q '"agents"' "${cfg}"; then ok "one remove of bundle + catalog takes every agents key back"; else ko "one remove of bundle + catalog takes every agents key back" "$(cat "${cfg}")"; fi

echo "== opencode catalog: --purge-cache =="

home="$(new_home)"
cache="${home}/.cache/opencode"
mkdir -p "${cache}/npm/${SLIM_PKG}/1/node_modules/${SLIM}" "${cache}/packages/${SLIM}@3.0.4/node_modules" \
    "${cache}/node_modules/${SLIM}" "${cache}/npm/other-plugin@1.0.0"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --global
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --purge-cache --global
leftover="$(find "${cache}" -mindepth 2 -maxdepth 2 -printf '%P\n' | sort | tr '\n' ' ')"
if [[ "${leftover}" == "npm/other-plugin@1.0.0 " ]]; then ok "--purge-cache removes the npm, packages and node_modules layouts only"; else ko "--purge-cache removes the npm, packages and node_modules layouts only" "${leftover}"; fi

home="$(new_home)"
mkdir -p "${home}/.cache/opencode/npm/${SLIM_PKG}"
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}" --global
if [[ -d "${home}/.cache/opencode/npm/${SLIM_PKG}" ]]; then ok "remove without --purge-cache keeps the package cache"; else ko "remove without --purge-cache keeps the package cache"; fi

home="$(new_home)"
rc=0
out="$(run_install "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --purge-cache --global)" || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "--purge-cache without remove is rejected"; else ko "--purge-cache without remove is rejected"; fi
assert_contains "${out}" "--purge-cache is only valid with 'remove'" "--purge-cache without remove explains why"
if [[ ! -e "${home}/.config/opencode/opencode.json" ]]; then ok "a rejected --purge-cache run writes nothing"; else ko "a rejected --purge-cache run writes nothing"; fi

echo "== opencode catalog: project scope (default) =="

# Default scope is project: a catalog plugin lands in <project>/opencode.json
# and <project>/.opencode/, never in ~/.config/opencode.
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}"
assert_contains "$(cat "${home}/project/opencode.json" 2>/dev/null)" "${SLIM_PKG}" "default scope merges the catalog item into <project>/opencode.json"
if cmp -s "${SLIM_COMPANION_SRC}" "${home}/project/.opencode/${SLIM}.json"; then ok "default scope ships the companion into <project>/.opencode"; else ko "default scope ships the companion into <project>/.opencode"; fi
if [[ ! -e "${home}/.config/opencode/opencode.json" && ! -e "${home}/.config/opencode/${SLIM}.json" && ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then
    ok "default scope leaves the global opencode config alone"
else
    ko "default scope leaves the global opencode config alone"
fi
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins "${SLIM}"
if [[ ! -e "${home}/project/opencode.json" && ! -e "${home}/project/.opencode/${SLIM}.json" ]]; then
    ok "default remove takes the project files back"
else
    ko "default remove takes the project files back" "$(cat "${home}/project/opencode.json" 2>/dev/null)"
fi

# Explicit --project behaves the same.
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins "${SLIM}" --project
assert_contains "$(cat "${home}/project/opencode.json" 2>/dev/null)" "${SLIM_PKG}" "--project merges the catalog item into <project>/opencode.json"

# A bare plugins intent at default scope has nothing project-capable: the
# bundle plugins group is dropped with a notice and nothing is written.
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins
assert_contains "${INSTALL_OUT}" "the plugins group is global-only" "default bare plugins intent drops the bundle group with a notice"
if [[ ! -e "${home}/project/opencode.json" && ! -e "${home}/.config/opencode/opencode.json" ]]; then ok "default bare plugins intent writes nothing"; else ko "default bare plugins intent writes nothing"; fi

home="$(new_home)"
rc=0
out="$(run_install "${home}" sync --target opencode --intent plugins --plugins "./ycc-sensitive-guard,${SLIM}" --project)" || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "--project with a bundle plugin is rejected"; else ko "--project with a bundle plugin is rejected"; fi
assert_contains "${out}" "supports catalog plugins only" "--project with a bundle plugin explains why"
if [[ ! -e "${home}/project/opencode.json" ]]; then ok "a rejected --project run writes nothing"; else ko "a rejected --project run writes nothing"; fi

rc=0
out="$(run_install "${home}" sync --target opencode --intent plugins --project)" || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "--project with a bare plugins intent is rejected"; else ko "--project with a bare plugins intent is rejected"; fi
assert_contains "${out}" "--project cannot carry the plugins group for target 'opencode' (global-only)" "--project bare plugins intent names the global-only group"

# The settings group is project-capable now: settings + catalog plugin succeed.
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent settings,plugins --plugins "${SLIM}" --project
project_cfg="$(cat "${home}/project/opencode.json")"
assert_contains "${project_cfg}" "${SLIM_PKG}" "--project settings,plugins carries the catalog plugin"
assert_contains "${project_cfg}" '"model"' "--project settings,plugins carries the bundle settings"
assert_not_contains "${project_cfg}" "ycc-sensitive-guard" "--project settings,plugins carries no bundle plugin"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
