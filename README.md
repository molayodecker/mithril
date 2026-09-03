# Mithril

Mithril is the new Phoenix/Elixir backend for Instaclean.

This repository will replace application behavior currently implemented in the private `instaclean-schema` Supabase project. The migration will be incremental: PostgreSQL remains the source of truth while Supabase-specific Edge Functions, RPC-heavy business logic, authentication coupling, scheduled jobs, and realtime behavior move behind Phoenix/Ecto interfaces.

> Migration safety: `instaclean-schema` is private while this repository is currently public. Do not copy private source, credentials, production identifiers, or operational configuration here until repository visibility and disclosure have been intentionally reviewed.

See the migration branch/PR for the Phoenix bootstrap and cutover plan.
