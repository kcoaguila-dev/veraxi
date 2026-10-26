import sys

BASH_COMPLETION = """
# Bash completion for veraxi / vx
_veraxi_completions() {
    local cur prev words cword
    _init_completion -n : || return

    local commands="chat init brief research review ingest login whoami logout stats hook schema trace check context remember resolve memory mcp completion"
    local mcp_commands="install doctor query"
    local hook_commands="install uninstall"
    local clients="claude cursor claude-code cline all"

    if [[ ${cword} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- ${cur}) )
        return 0
    fi

    case "${prev}" in
        mcp)
            COMPREPLY=( $(compgen -W "${mcp_commands}" -- ${cur}) )
            return 0
            ;;
        hook)
            COMPREPLY=( $(compgen -W "${hook_commands}" -- ${cur}) )
            return 0
            ;;
        --client)
            COMPREPLY=( $(compgen -W "${clients}" -- ${cur}) )
            return 0
            ;;
        --endpoint|--key|--tenant|--limit|--commit|--context|--min-score|--hops)
            return 0
            ;;
        completion)
            COMPREPLY=( $(compgen -W "bash zsh" -- ${cur}) )
            return 0
            ;;
    esac

    if [[ "${words[1]}" == "mcp" && ${cword} -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "${mcp_commands}" -- ${cur}) )
        return 0
    fi
}

complete -F _veraxi_completions veraxi
complete -F _veraxi_completions vx
"""

ZSH_COMPLETION = """
#compdef veraxi vx

_veraxi() {
    local -a commands
    commands=(
        'chat:Start interactive knowledge assistant'
        'init:Initialize Veraxi agent instructions'
        'brief:Generate structured briefing doc'
        'review:Audit git diff against knowledge base'
        'ingest:Ingest documents or URLs'
        'login:Authenticate and persist API credentials'
        'whoami:Display active user identity and status'
        'logout:Remove stored credentials'
        'stats:Display database and knowledge graph health'
        'hook:Manage Git pre-commit hooks for architectural review'
        'schema:Display knowledge graph ontology and schema'
        'trace:Trace multi-hop causal/dependency paths for an entity'
        'check:Grounding and factual accuracy gatekeeper for CI'
        'context:Assemble token-efficient grounding context for agents'
        'remember:Save an architectural rule or constraint to memory'
        'resolve:Mark an issue or caveat as resolved (prevents re-solving)'
        'memory:Inspect and list architectural memories'
        'mcp:Manage MCP server configuration'
        'completion:Generate shell auto-completion script'
    )

    if (( CURRENT == 2 )); then
        _describe 'command' commands
    fi
}

_veraxi "$@"
"""


def run_completion(shell: str = "bash"):
    if shell == "bash":
        print(BASH_COMPLETION.strip())
    elif shell == "zsh":
        print(ZSH_COMPLETION.strip())
    else:
        print(f"Unsupported shell '{shell}'. Supported: bash, zsh.", file=sys.stderr)
        sys.exit(1)
