from typing import List, Dict, Any
import pandas as pd
from splink import Linker, SettingsCreator, block_on
from splink.backends.duckdb import DuckDBAPI
import splink.comparison_library as cl
import duckdb

def resolve_entities(entities: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Deduplication pass using Splink to collapse similar entities.
    Expects entities to have 'name' and 'type'.
    """
    if not entities:
        return []

    # We only deduplicate within the same type.
    # Convert list of dicts to a pandas DataFrame
    # Splink requires a unique id column
    df_data = []
    for i, ent in enumerate(entities):
        row = {
            "unique_id": str(i),
            "name": ent["name"],
            "type": ent["type"],
            "properties": str(ent.get("properties", {})) # store as string for now if needed, though we primarily match on name
        }
        df_data.append(row)

    df = pd.DataFrame(df_data)

    settings = SettingsCreator(
        link_type="dedupe_only",
        blocking_rules_to_generate_predictions=[
            block_on("type", "name")  # Simple exact match for now, or just block on type and use jarowinkler on name
        ],
        comparisons=[
            cl.ExactMatch("type"),
            cl.ExactMatch("name") # Using ExactMatch since the others require proper training
        ],
        retain_matching_columns=True,
        retain_intermediate_calculation_columns=True,
    )

    # Initialize Linker with DuckDB backend
    # DuckDB is the default and easiest memory backend for Splink
    linker = Linker(df, settings, db_api=DuckDBAPI(connection=duckdb.connect()))

    # For small datasets or when using exact matches, EM training will often fail or is unnecessary.
    # We will only attempt EM training if we have a sufficiently large dataset.
    if len(df) > 10:
        try:
            linker.training.estimate_probability_two_random_records_match(
                [block_on("type")], recall=0.7
            )
            linker.training.estimate_u_using_random_sampling(max_pairs=1e4)

            linker.training.estimate_parameters_using_expectation_maximisation(
                block_on("type")
            )
        except Exception:
            pass

    try:
        # Predict duplicates
        df_predict = linker.inference.predict(threshold_match_probability=0.5)

        # Cluster the predictions to find the groups
        clusters = linker.clustering.cluster_pairwise_predictions_at_threshold(df_predict, 0.5)

        cluster_df = clusters.as_pandas_dataframe()
    except Exception as e:
        # If Splink fails (e.g., zero matches, empty dataset after blocking), just return original
        return entities

    # Map clusters back to our entities
    # The cluster_df has 'unique_id' and 'cluster_id'
    # We will pick one representative for each cluster (e.g., the first one we see)

    # Create a mapping of cluster_id to the canonical entity
    # We can just group by cluster_id
    if cluster_df.empty:
        return entities

    resolved_entities = []
    cluster_groups = cluster_df.groupby("cluster_id")

    for cluster_id, group in cluster_groups:
        # Get the original unique_ids in this cluster
        ids_in_cluster = group["unique_id"].tolist()

        # We merge their properties, taking the longest name as the canonical name
        canonical_ent = None
        merged_props = {}

        cluster_ents = [entities[int(uid)] for uid in ids_in_cluster]

        # Sort by length of name descending to pick the most descriptive
        cluster_ents.sort(key=lambda x: len(x["name"]), reverse=True)

        canonical_ent = cluster_ents[0].copy()

        # Merge properties
        for ent in cluster_ents:
            props = ent.get("properties", {})
            for k, v in props.items():
                if k not in merged_props:
                    merged_props[k] = v

        canonical_ent["properties"] = merged_props
        resolved_entities.append(canonical_ent)

    return resolved_entities
