# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records (ADRs) for the Veraxi project.

An ADR is a short text file in a format similar to an Alexandrian pattern that describes a set of forces and a single decision in response to those forces.

## Why do we use ADRs?
To prevent "institutional amnesia." When a new developer joins the project, they shouldn't have to guess *why* we chose Neo4j over PostgreSQL, or *why* we use Flutter instead of React. The historical context, alternatives considered, and final decision are permanently recorded here.

## How to add a new ADR
When making a significant architectural or technological decision, copy the format of existing ADRs and create a new sequential file (e.g., `0004-use-redis-for-caching.md`).
