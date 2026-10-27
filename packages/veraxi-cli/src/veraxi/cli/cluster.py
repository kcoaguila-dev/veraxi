import datetime
import json
import sys
from veraxi.cli.memory import _resolve_project_scope


def _get_utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def get_cluster_repos(repo_name: str, tenant_id: str = "default") -> list[str]:
    """
    Returns all sister repositories grouped in clusters with the given repository.
    Always includes the repo itself.
    """
    if not repo_name:
        return []

    sister_repos = {repo_name}
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        rows = neo4j.execute_read(
            """
            MATCH (c:Cluster)
            WHERE (c.tenant_id = $tenant_id OR c.tenant_id = 'default')
              AND $repo IN c.repos
            RETURN c.repos as repos
            """,
            {"tenant_id": tenant_id, "repo": repo_name},
        )
        neo4j.close()
        for r in rows:
            for rep in r.get("repos", []):
                sister_repos.add(rep)
    except Exception:
        pass

    return sorted(list(sister_repos))


def run_cluster(
    action: str = "list",
    name: str | None = None,
    repos: list[str] | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Manages cross-repository architectural clusters (e.g., auth-stack: [frontend-web, auth-service]).
    Bridges knowledge graph context across microservices without global memory leakage.
    """
    action = (action or "list").strip().lower()
    now_iso = _get_utc_now()

    bold = "\033[1m"
    green = "\033[32m"
    cyan = "\033[36m"
    reset = "\033[0m"

    if action in ("add", "create"):
        if not name or not name.strip():
            print("Error: cluster name is required to create or add repos.", file=sys.stderr)
            sys.exit(1)

        name = name.strip()
        repo_list = [r.strip() for r in (repos or []) if r.strip()]
        if not repo_list:
            # Auto-detect current repo
            curr_repo = _resolve_project_scope()
            repo_list = [curr_repo]

        cluster_data = None
        try:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            config = get_config()
            neo4j = Neo4jStorageClient.from_config(config)

            # Read existing
            existing = neo4j.execute_read(
                """
                MATCH (c:Cluster {name: $name})
                WHERE (c.tenant_id = $tenant_id OR c.tenant_id = 'default')
                RETURN c.repos as repos
                """,
                {"name": name, "tenant_id": tenant_id},
            )
            merged_repos = set(repo_list)
            if existing and existing[0].get("repos"):
                for r in existing[0]["repos"]:
                    merged_repos.add(r)

            final_repos = sorted(list(merged_repos))

            neo4j.execute_write(
                """
                MERGE (c:Cluster {name: $name, tenant_id: $tenant_id})
                SET c.repos = $repos, c.updated_at = $now_iso
                """,
                {"name": name, "tenant_id": tenant_id, "repos": final_repos, "now_iso": now_iso},
            )
            neo4j.close()
            cluster_data = {"name": name, "repos": final_repos, "updated_at": now_iso}
        except Exception as e:
            print(f"Warning: Cluster database write failed ({e}).", file=sys.stderr)

        if as_json:
            print(json.dumps(cluster_data or {"name": name, "repos": repo_list}, indent=2))
            return

        final_list = cluster_data["repos"] if cluster_data else repo_list
        print(f"\n{bold}{green}✓ Updated repository cluster{reset} [{cyan}{name}{reset}]:")
        print(f"  Repositories ({len(final_list)}): {', '.join(final_list)}")
        print("  These services now share architectural rules and context automatically.\n")

    elif action == "list":
        clusters = []
        try:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            config = get_config()
            neo4j = Neo4jStorageClient.from_config(config)

            rows = neo4j.execute_read(
                """
                MATCH (c:Cluster)
                WHERE (c.tenant_id = $tenant_id OR c.tenant_id = 'default')
                RETURN c.name as name, c.repos as repos, c.updated_at as updated_at
                ORDER BY c.name ASC
                """,
                {"tenant_id": tenant_id},
            )
            neo4j.close()
            clusters = rows
        except Exception:
            pass

        if as_json:
            print(json.dumps(clusters, indent=2))
            return

        print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
        print(f"{bold}{cyan}║                 Veraxi Repository Clusters                         ║{reset}")
        print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

        if not clusters:
            print("\n  No cross-repository clusters configured yet.")
            print("  Use 'veraxi cluster add <name> <repo1> <repo2>' to group microservices.\n")
            return

        print(f"\n  Active Architectural Clusters ({len(clusters)}):")
        print("  " + "─" * 68)

        for c in clusters:
            reps = c.get("repos", [])
            print(f"  {bold}{cyan}{c['name']}{reset} ({len(reps)} repos):")
            for r in reps:
                print(f"    {green}•{reset} {r}")
        print()

    elif action == "remove":
        if not name or not name.strip():
            print("Error: cluster name is required to remove.", file=sys.stderr)
            sys.exit(1)

        name = name.strip()
        target_repo = repos[0].strip() if repos else None

        try:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            config = get_config()
            neo4j = Neo4jStorageClient.from_config(config)

            if target_repo:
                existing = neo4j.execute_read(
                    """
                    MATCH (c:Cluster {name: $name})
                    WHERE (c.tenant_id = $tenant_id OR c.tenant_id = 'default')
                    RETURN c.repos as repos
                    """,
                    {"name": name, "tenant_id": tenant_id},
                )
                if existing and existing[0].get("repos"):
                    curr_list = [r for r in existing[0]["repos"] if r != target_repo]
                    neo4j.execute_write(
                        """
                        MATCH (c:Cluster {name: $name})
                        WHERE (c.tenant_id = $tenant_id OR c.tenant_id = 'default')
                        SET c.repos = $repos
                        """,
                        {"name": name, "tenant_id": tenant_id, "repos": curr_list},
                    )
                print(f"{bold}{green}✓ Removed '{target_repo}' from cluster '{name}'{reset}")
            else:
                neo4j.execute_write(
                    """
                    MATCH (c:Cluster {name: $name})
                    WHERE (c.tenant_id = $tenant_id OR c.tenant_id = 'default')
                    DETACH DELETE c
                    """,
                    {"name": name, "tenant_id": tenant_id},
                )
                print(f"{bold}{green}✓ Deleted cluster '{name}'{reset}")
            neo4j.close()
        except Exception as e:
            print(f"Warning: Failed to update cluster ({e}).", file=sys.stderr)

    elif action == "link":
        if not name:
            print("Error: target repo name required to link.", file=sys.stderr)
            sys.exit(1)

        target_repo = name.strip()
        current_repo = _resolve_project_scope()
        cluster_name = f"{current_repo}-{target_repo}"
        run_cluster("add", name=cluster_name, repos=[current_repo, target_repo], tenant_id=tenant_id, as_json=as_json)
