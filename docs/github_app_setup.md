# Veraxi GitHub App Setup Guide

This guide covers registering and configuring the **Selected-Repos Read-Only GitHub App** for Cloud SaaS (`veraxi.me`) and self-hosted Docker / Cloud Run deployments.

---

## 1. Register the GitHub App on GitHub

Navigate to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App** (or Organization Settings for an org-owned app) and configure:

- **GitHub App name**: e.g. `Veraxi Code Intel`
- **Homepage URL**: `https://veraxi.me` (or your `PUBLIC_APP_URL`)
- **Callback URL**: `https://<your-api-host>/api/v1/github-app/callback`
- **Setup URL**: `https://<your-api-host>/api/v1/github-app/callback`
  - ✅ Check **Redirect on update** (ensures "Manage on GitHub" repo-selection changes flow back to Veraxi cleanly)
- **Request user authorization (OAuth) during installation**: ✅ **Checked** *(Mandatory: prevents `installation_id` IDOR hijacking by verifying ownership via `GET /user/installations`)*
- **Expire user authorization tokens**: ✅ **Checked**
- **Webhook**:
  - ✅ **Active**
  - **Webhook URL**: `https://<your-api-host>/api/v1/github-app/webhook`
  - **Webhook secret**: Generate a 32+ byte random hex string (`openssl rand -hex 32`)
- **Repository permissions** *(strictly read-only)*:
  - `Contents`: **Read-only**
  - `Metadata`: **Read-only**
  - All other Repository, Organization, and Account permissions: **No access**
- **Subscribe to events**:
  - `Installation`
  - `Installation repositories`
  - `Push`
  - `Repository`
- **Where can this GitHub App be installed?**: `Any account` (for SaaS) or `Only on this account` (for private/self-hosted)

After creating the app:
1. Note the **App ID**, **URL slug** (`https://github.com/apps/<slug>`), and **Client ID**.
2. Generate a **Client Secret**.
3. Click **Generate a private key** to download the `.pem` file.

---

## 2. Apply Supabase Database Migration

Run [008_github_app.sql](file:///home/ubuntu/src/ai/veraxi/backend/migrations/008_github_app.sql) in the Supabase SQL Editor (or `psql`). This creates `github_app_installations` and `github_app_repos` with Row-Level Security enabled.

---

## 3. Configure Environment Variables

Set these in `backend/.env` (or Cloud Run / Secret Manager):

```env
INTEGRATION_ENCRYPTION_KEY=<fernet-key-or-strong-passphrase>
OAUTH_REDIRECT_BASE_URL=https://api.veraxi.me
# If Flutter Web is served under a subpath (e.g. /app/), include it in PUBLIC_APP_URL
# so popup-blocked fallback redirects land on the app instead of the landing page:
PUBLIC_APP_URL=https://veraxi.me/app

GITHUB_APP_ID=123456
GITHUB_APP_SLUG=veraxi-code-intel
GITHUB_APP_CLIENT_ID=Iv1.xxxxxxxxxxxx
GITHUB_APP_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxx
# Either inline PEM (with \n escapes) OR path to mounted .pem file:
GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----"
# GITHUB_APP_PRIVATE_KEY_PATH=/secrets/github-app.pem
# Optional secondary key for zero-downtime key rotation:
# GITHUB_APP_PRIVATE_KEY_SECONDARY=
GITHUB_APP_WEBHOOK_SECRET=<your-32-byte-hex-secret>
GITHUB_APP_MAX_REPO_MB=100
```

> [!WARNING]
> Never expose `GITHUB_APP_PRIVATE_KEY` or `GITHUB_APP_WEBHOOK_SECRET` to frontend builds or commit them to git. In production, `INTEGRATION_ENCRYPTION_KEY` is mandatory (the vault fails closed).

---

## 4. Zero-Downtime Private Key Rotation

1. Generate a second private key in GitHub App settings (do **not** delete the old key yet).
2. Set `GITHUB_APP_PRIVATE_KEY_SECONDARY` to the new key, or set `GITHUB_APP_PRIVATE_KEY` to the new key and `GITHUB_APP_PRIVATE_KEY_SECONDARY` to the old key.
3. Deploy/restart the backend and verify token minting succeeds.
4. Revoke the old key on GitHub and clear `GITHUB_APP_PRIVATE_KEY_SECONDARY`.

---

## 5. Staging Smoke-Test Checklist

1. Open **Connect a repository → GitHub App** in Veraxi.
2. Click **Install GitHub App & Select Repos**, choose **Only select repositories**, pick 1 private test repo, and confirm the popup closes automatically.
3. Verify the repo appears in the picker, select it, and click **Connect & Index**.
4. Ask a question in Code Chat and click a file citation — confirm `GET /api/v1/code/file` serves the exact file at the pinned commit SHA (`source: "github_app"`).
5. Push a 1-file commit to the default branch on GitHub and verify the `push` webhook triggers an incremental update in the ARQ worker.
6. Remove the repo from the GitHub App installation settings on GitHub and confirm Neo4j code nodes and `github_app_repos` rows are purged automatically.

---

## 6. Troubleshooting

- **`invalid_app_config` / `404 Not Found` on `/login/oauth/access_token`**: Verify `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_CLIENT_SECRET` in `backend/.env` match your GitHub App settings exactly (a single-character typo causes GitHub to return `404`). Check `veraxi-backend-1` startup logs for `GitHub App credential preflight failed`.
- **Applying `backend/.env` changes in Docker Compose**: Always run `docker compose up -d --force-recreate backend worker` after editing `backend/.env` so Docker reloads `env_file` values into both containers (`docker restart` reuses the old environment).
