# Cloudflare R2 on Fly.io

## Purpose

Mithril runs on Fly.io and uses Cloudflare R2 bucket `insta-production` for production object storage.

PostgreSQL remains the source of truth for transactional and relational state. R2 is for object/blob data such as uploaded media, property photos, cleaner documents where appropriate, generated exports, and other file payloads.

## R2 endpoint

Cloudflare account endpoint:

```text
https://90a7b11a99d10b148259091ea6b4207c.r2.cloudflarestorage.com
```

Bucket:

```text
insta-production
```

Region for S3-compatible clients:

```text
auto
```

## Credentials

Create an R2 API token scoped to `insta-production`. Prefer the minimum permissions required by Mithril. For normal application object reads/writes, scope the token to Object Read & Write for this bucket only.

Never commit the Access Key ID or Secret Access Key.

Configure Fly.io secrets:

```bash
fly secrets set \
  R2_ACCESS_KEY_ID='<access-key-id>' \
  R2_SECRET_ACCESS_KEY='<secret-access-key>'
```

Non-secret configuration can live in `fly.toml` or deployment environment:

```text
R2_BUCKET=insta-production
R2_ENDPOINT=https://90a7b11a99d10b148259091ea6b4207c.r2.cloudflarestorage.com
R2_REGION=auto
```

## Migration from Supabase Storage

Do not replace object references blindly. Use a staged migration:

1. Inventory every Supabase Storage bucket and every database column containing object paths/URLs.
2. Decide the destination prefix in `insta-production` for each source bucket.
3. Copy objects to R2 while leaving Supabase Storage intact.
4. Verify object counts, sizes, checksums where practical, and MIME metadata.
5. Add a Mithril storage adapter that reads R2 first and can temporarily fall back to the legacy source during migration.
6. Switch new uploads to R2.
7. Backfill old database object references only when consumers no longer depend on Supabase URLs.
8. Remove fallback reads after parity and retention checks.
9. Delete legacy objects only under an explicit cleanup plan.

## Suggested object prefixes

Keep one production bucket but use explicit namespaces rather than a flat keyspace:

```text
avatars/
properties/
cleaner-documents/
booking-media/
quick-tasks/
cleaning-scans/
exports/
```

Preserve immutable object IDs in keys where possible. Avoid embedding customer names, phone numbers, email addresses, or other sensitive values in object keys.

## Application boundary

Mithril should expose a storage behaviour/interface rather than coupling business contexts directly to an S3 client. Suggested operations:

```text
put_object(key, body, content_type)
get_object(key)
delete_object(key)
presign_get(key, expires_in)
presign_put(key, expires_in, content_type)
head_object(key)
```

Business contexts should store stable object keys in PostgreSQL, not provider-specific public URLs. This keeps Cloudflare R2 replaceable and makes signed URL generation a runtime concern.

## Upload strategy

For large user uploads, prefer presigned PUT URLs so mobile/web clients upload directly to R2 rather than proxying the full payload through a Fly Machine. Mithril authorizes the upload, chooses the object key, creates the signed URL, and records the resulting key after validation.

## Security

- Keep the bucket private unless a specific public delivery path is intentionally designed.
- Use short-lived presigned URLs for private objects.
- Scope R2 credentials to `insta-production` only.
- Separate application credentials from migration/import credentials if bulk migration requires broader permissions.
- Do not log signed URLs, access keys, or private object contents.
- Treat identity documents and private property instructions as high-sensitivity objects.

## Data synchronization

If `insta-production` already contains the authoritative object set, Mithril does not need to copy R2 data into Fly.io local disk. Fly Machine root filesystems are not the durable object store. Mithril should access R2 remotely through the S3-compatible API.

For one-time migration jobs from Supabase Storage into R2, run a dedicated import task or release command with idempotency and a migration ledger. Do not make bucket mirroring part of every application boot.
