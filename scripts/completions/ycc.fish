# fish completion for ycc (install.sh) — install: ycc completion --shell fish --install

function __ycc_csv --argument-names values
    set -l tok (commandline -ct)
    set -l head (string replace -r '[^,]*$' '' -- $tok)
    for v in (string split ' ' -- $values)
        echo $head$v
    end
end

# __ycc_list_names <kind> — a kind's names, from 'ycc list <kind>' for the --target on the line.
function __ycc_list_names --argument-names kind
    set -l words (commandline -opc)
    set -l targets all
    set -l i (contains -i -- --target $words)
    and set -q words[(math $i + 1)]
    and set targets $words[(math $i + 1)]
    __ycc_csv (string join ' ' -- ($words[1] list $kind --target $targets 2>/dev/null))
end

set -l subs install sync remove migrate cli completion list list-mcps
set -l none "not __fish_seen_subcommand_from $subs"
set -l isr "__fish_seen_subcommand_from install sync remove"
set -l is "__fish_seen_subcommand_from install sync"
set -l ir "__fish_seen_subcommand_from install remove"
set -l sr "__fish_seen_subcommand_from sync remove"
set -l inst "__fish_seen_subcommand_from install"

complete -c ycc -f
complete -c ycc -n $none -a install -d 'Initial setup (base + opt-in steps)'
complete -c ycc -n $none -a sync -d 'Sync intents to targets'
complete -c ycc -n $none -a remove -d 'Remove installer-managed config'
complete -c ycc -n $none -a migrate -d 'Preview or apply native package migration'
complete -c ycc -n $none -a cli -d 'Link install.sh onto PATH as ycc'
complete -c ycc -n $none -a completion -d 'Print or install shell completion'
complete -c ycc -n $none -a list -d 'List selectable kinds or a kind\'s names'
complete -c ycc -n $none -a list-mcps -d 'Alias of list mcps'

complete -c ycc -n $isr -l target -x -a '(__ycc_csv "claude cursor codex opencode agents omp all")' -d Targets
complete -c ycc -n $isr -l skills-home -x -a 'agents native' -d 'Duplicate-skills choice'
complete -c ycc -n $sr -l intent -x -a '(__ycc_csv "base skills agents commands settings rules mcp hooks plugins mods")' -d Intents
# --<kind> selectors: one per kind from 'ycc list', names from 'ycc list <kind>'.
# On install, --hooks is the boolean "also link hooks" step flag (below).
set -l kinds (ycc list 2>/dev/null)
for kind in $kinds
    set -l cond $isr
    test $kind = hooks; and set cond $sr
    complete -c ycc -n $cond -l $kind -x -a "(__ycc_list_names $kind)" -d "Only these $kind"
end
complete -c ycc -n "__fish_seen_subcommand_from list; and not __fish_seen_subcommand_from $kinds" -a "$kinds" -d 'Selectable kind'
complete -c ycc -n '__fish_seen_subcommand_from list list-mcps' -l target -x -a '(__ycc_csv "claude cursor codex opencode agents omp all")' -d Targets
complete -c ycc -n $ir -l only -x -a '(__ycc_csv "base dedupe skills agents commands settings rules mcp hooks mods")' -d Steps
complete -c ycc -n $is -l mode -x -a 'local repo' -d 'Marketplace source mode'
complete -c ycc -n $inst -l package -x -a '(__ycc_csv "ycc ycc-mcp ycc-hooks ycc-rules")' -d 'Install package closures'
complete -c ycc -n $inst -l settings -d 'Also merge settings'
complete -c ycc -n $inst -l rules -d 'Also link rules'
complete -c ycc -n $inst -l mcp -d 'Also merge MCP servers'
complete -c ycc -n $inst -l hooks -d 'Also link hooks'
complete -c ycc -n $isr -l project -d 'Write into the current project'
complete -c ycc -n $isr -l global -d 'Write into user-global config'
complete -c ycc -n '__fish_seen_subcommand_from remove' -l purge-cache -d 'Also delete the opencode package cache of removed catalog plugins'
complete -c ycc -n $is -l with-deps -d 'Also select ycc: dependencies of --skills/--agents'
complete -c ycc -n $isr -l dry-run -d 'Preview without writing (mcp and omp steps; others skipped)'
complete -c ycc -n '__fish_seen_subcommand_from migrate' -l target -x -a '(__ycc_csv "claude codex cursor omp all")' -d Targets
complete -c ycc -n '__fish_seen_subcommand_from migrate' -l apply -d 'Apply migration (default: dry-run)'
complete -c ycc -n '__fish_seen_subcommand_from migrate' -l marketplace-source -x -a '(__fish_complete_directories)' -d 'Eligible native Codex marketplace'

complete -c ycc -n '__fish_seen_subcommand_from cli' -l dir -x -a '(__fish_complete_directories)' -d 'Install directory'
complete -c ycc -n '__fish_seen_subcommand_from completion' -l shell -x -a 'bash zsh fish' -d Shell
complete -c ycc -n '__fish_seen_subcommand_from completion' -l install -d 'Install for the shell'

complete -c ycc -n '__fish_seen_subcommand_from install sync remove cli completion' -l force -d 'Replace existing / repo values win'
complete -c ycc -l help -d 'Show help'
