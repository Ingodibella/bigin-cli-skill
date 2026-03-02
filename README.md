<p align="center">
  <h1 align="center">bigin-cli</h1>
  <p align="center">
    A Bash CLI for the <a href="https://www.bigin.com/">Zoho Bigin</a> CRM API.<br>
    Built for AI agents and automation workflows.
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/bash-4.0%2B-blue?logo=gnubash&logoColor=white" alt="Bash 4.0+">
    <img src="https://img.shields.io/badge/Zoho_Bigin-v2_API-red?logo=zoho&logoColor=white" alt="Bigin v2">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
    <img src="https://img.shields.io/badge/AI_agent-ready-blueviolet" alt="AI Agent Ready">
  </p>
</p>

---

## Why this exists

Zoho's official MCP server for Bigin is unreliable. COQL doesn't exist in Bigin v2. The API has quirks that trip up both humans and AI agents (mandatory `fields` parameter, `Pipelines` instead of `Deals`, `Sub_Pipeline` not criteria-searchable).

This CLI wraps all of that into a single Bash script with guardrails, retry logic, and auto-generated metadata. Point your AI agent at `skills/bigin/SKILL.md` and let it work.

## Quick start

```bash
git clone https://github.com/Ingodibella/bigin-cli-skill.git
cd bigin-cli-skill
chmod +x scripts/bigin.sh
```

Set up OAuth ([details below](#oauth-setup)), then:

```bash
bash scripts/bigin.sh map              # generate your org's metadata
bash scripts/bigin.sh deals "Acme"     # search deals
bash scripts/bigin.sh contacts "Smith" # search contacts
```

## For AI agents

> **TL;DR:** Point your agent to [`skills/bigin/SKILL.md`](skills/bigin/SKILL.md), give it shell access, done.

```
skills/bigin/SKILL.md    →  Agent instructions (triggers, commands, anti-patterns)
scripts/bigin.sh         →  The CLI (all API calls go through here)
bigin-map.json           →  Auto-generated org metadata (stages, pipelines, fields)
```

The agent calls `bash scripts/bigin.sh <command>`. Guardrails prevent accidental writes: the agent must explicitly set `BIGIN_WRITE=1` for mutations and `BIGIN_CONFIRM=1` for deletions.

All errors return structured JSON to stderr:

```json
{"success": false, "error_code": "WRITE_BLOCKED", "message": "Write operations require BIGIN_WRITE=1", "retryable": false}
```

No Zoho error interpretation needed.

---

## Features

| | |
|---|---|
| **CRUD** | Full create/read/update/delete for Contacts, Accounts, Pipelines (Deals), Products, Tasks, Events |
| **Deal management** | Stage moves with fuzzy matching and validation against `bigin-map.json` |
| **Search** | Word search + criteria search (auto-handles Bigin's `Sub_Pipeline` limitation) |
| **Metadata cache** | Auto-generated `bigin-map.json` with pipelines, stages, sub-pipelines, fields |
| **OAuth** | Auto token refresh with 60s safety margin, atomic credential writes |
| **Retry** | Exponential backoff on 429/5xx (3 attempts) |
| **Guardrails** | Read-only default. `BIGIN_WRITE=1` for writes. `BIGIN_CONFIRM=1` for deletes |
| **Error output** | Structured JSON on stderr, parseable by agents |
| **Field defaults** | Sensible defaults per module (Bigin v2 requires explicit `fields`) |

## Prerequisites

- `bash` 4.0+
- `curl`
- `jq`
- `python3` (for stage validation + map generation)
- A [Zoho Bigin](https://www.bigin.com/) account

---

## OAuth setup

Bigin uses OAuth 2.0. You need a refresh token to get started.

<details>
<summary><strong>Step 1: Register a Self Client</strong></summary>

1. Go to [Zoho API Console](https://api-console.zoho.eu/) (use `.com` / `.in` / `.com.au` for other regions)
2. Click **Add Client** > **Self Client**
3. Note your **Client ID** and **Client Secret**
</details>

<details>
<summary><strong>Step 2: Generate a Grant Token</strong></summary>

1. In the Self Client, click **Generate Code**
2. Enter the required scopes:
   ```
   ZohoBigin.modules.ALL,ZohoBigin.settings.ALL,ZohoBigin.org.READ
   ```
3. Set a description, choose your portal, click **Create**
4. Copy the generated code (valid for ~3 minutes)
</details>

<details>
<summary><strong>Step 3: Exchange for Refresh Token</strong></summary>

```bash
curl -X POST "https://accounts.zoho.eu/oauth/v2/token" \
  -d "grant_type=authorization_code" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "code=YOUR_GRANT_TOKEN"
```

The response contains your `refresh_token`. Save it, it doesn't expire.
</details>

<details>
<summary><strong>Step 4: Create credentials file</strong></summary>

Create `~/.bigin-oauth.json`:

```json
{
  "client_id": "1000.XXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "client_secret": "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "refresh_token": "1000.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "access_token": "",
  "expires_at": 0,
  "token_endpoint": "https://accounts.zoho.eu/oauth/v2/token",
  "api_base": "https://www.zohoapis.eu/bigin/v2"
}
```

The CLI auto-refreshes `access_token` on first use.

**Region endpoints:**

| Region | Token endpoint | API base |
|--------|---------------|----------|
| EU | `accounts.zoho.eu` | `www.zohoapis.eu` |
| US | `accounts.zoho.com` | `www.zohoapis.com` |
| IN | `accounts.zoho.in` | `www.zohoapis.in` |
| AU | `accounts.zoho.com.au` | `www.zohoapis.com.au` |
</details>

<details>
<summary><strong>Step 5: Generate your map</strong></summary>

```bash
bash scripts/bigin.sh map
```

Creates `bigin-map.json` with your org's pipelines, stages, sub-pipelines, and field definitions. Re-run whenever your Bigin setup changes.
</details>

---

## Usage

### Read (no flags needed)

```bash
# Deals
bash scripts/bigin.sh deals "Acme Corp"           # keyword search
bash scripts/bigin.sh deals --stage "Qualified"    # by stage
bash scripts/bigin.sh deal <deal_id>               # single deal

# Contacts & Accounts
bash scripts/bigin.sh contacts "Smith"
bash scripts/bigin.sh accounts "Google"

# Notes, Products, Metadata
bash scripts/bigin.sh notes Pipelines <deal_id>
bash scripts/bigin.sh products
bash scripts/bigin.sh modules
bash scripts/bigin.sh fields Pipelines
```

### Write (requires `BIGIN_WRITE=1`)

```bash
BIGIN_WRITE=1 bash scripts/bigin.sh note Pipelines <id> "Call" "Discussed pricing."
BIGIN_WRITE=1 bash scripts/bigin.sh move <deal_id> "Won"
BIGIN_WRITE=1 bash scripts/bigin.sh update Pipelines <id> '{"Amount": 15000}'
BIGIN_WRITE=1 bash scripts/bigin.sh create Contacts '{"First_Name":"Jane","Last_Name":"Doe"}'
```

### Delete (requires both flags)

```bash
BIGIN_WRITE=1 BIGIN_CONFIRM=1 bash scripts/bigin.sh delete Contacts <id>
```

### Raw API

```bash
bash scripts/bigin.sh raw GET "/Pipelines?fields=Deal_Name,Stage&per_page=10"
BIGIN_WRITE=1 bash scripts/bigin.sh raw PUT "/Pipelines/<id>" '{"data":[{"Stage":"Won"}]}'
```

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `BIGIN_CREDS_FILE` | `~/.bigin-oauth.json` | Path to OAuth credentials |
| `BIGIN_MAP_FILE` | `<script_dir>/../bigin-map.json` | Path to metadata cache |
| `BIGIN_WRITE` | `0` | Set to `1` to enable write operations |
| `BIGIN_CONFIRM` | `0` | Set to `1` to enable destructive operations |

---

## Bigin quirks you should know

Bigin v2 is not full Zoho CRM. These are the gotchas this CLI handles for you:

| Quirk | What happens | How bigin-cli handles it |
|---|---|---|
| `fields` is mandatory | GET without `fields` returns `REQUIRED_PARAM_MISSING` | Sensible defaults per module |
| Deals = `Pipelines` | API module name differs from UI | Documented in SKILL.md |
| `Sub_Pipeline` not searchable | Criteria search returns `INVALID_QUERY` | Auto-falls back to word search |
| No COQL | Scope doesn't exist in Bigin v2 | Word search + criteria search instead |
| Stage names vary by layout | Same name can exist in multiple layouts | Validated against `bigin-map.json` with layout disambiguation |

## Date formats

Bigin expects dates as `YYYY-MM-DD` (e.g., `2026-03-15`). DateTime fields use ISO 8601. Don't use locale formats like `DD.MM.YYYY` or `March 15, 2026`.

## Error handling

All errors output structured JSON to stderr:

```json
{"success": false, "error_code": "INVALID_STAGE", "message": "Stage not found in any layout", "retryable": false}
```

| Error code | Meaning | Retryable |
|---|---|---|
| `WRITE_BLOCKED` | Missing `BIGIN_WRITE=1` | No |
| `CONFIRM_REQUIRED` | Missing `BIGIN_CONFIRM=1` | No |
| `INVALID_JSON` | Malformed JSON input | No |
| `INVALID_STAGE` | Stage not in `bigin-map.json` | No |
| `AMBIGUOUS_STAGE` | Stage exists in multiple layouts | No |
| `TOKEN_REFRESH_FAILED` | OAuth refresh failed | Yes |
| `CONFIG_MISSING` | Credentials file not found | No |
| `CONFIG_INVALID` | Missing required fields in credentials | No |

HTTP 429/5xx errors are auto-retried with exponential backoff (3 attempts).

---

## Tests

```bash
bash tests/test.sh
```

15 smoke tests, no API calls required. Tests guardrails, JSON validation, error structure, and config handling.

## License

MIT
