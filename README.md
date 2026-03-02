# bigin-cli

A Bash CLI for the [Zoho Bigin](https://www.bigin.com/) CRM REST API. Built for AI agents and automation workflows.

## Features

- Full CRUD for all Bigin modules (Contacts, Accounts, Pipelines/Deals, Products, Tasks, Events)
- Deal stage management with fuzzy matching and validation
- Smart search (word search + criteria search)
- Auto-generated metadata cache (`bigin-map.json`) for pipelines, stages, and fields
- OAuth 2.0 with automatic token refresh
- Retry logic with exponential backoff (429, 5xx)
- Safety guardrails: read-only by default, write/delete require explicit flags
- Structured JSON error output
- Sensible field defaults per module

## Prerequisites

- `bash` (4.0+)
- `curl`
- `jq`
- `python3` (for stage validation and map generation)
- A [Zoho Bigin](https://www.bigin.com/) account

## Installation

```bash
git clone https://github.com/YOUR_USER/bigin-cli.git
cd bigin-cli
chmod +x scripts/bigin.sh
```

## OAuth Setup

Bigin uses OAuth 2.0. You need a **refresh token** to get started.

### Step 1: Register a Self Client

1. Go to [Zoho API Console](https://api-console.zoho.eu/) (use `.com` / `.in` / `.com.au` for other regions)
2. Click **Add Client** > **Self Client**
3. Note your **Client ID** and **Client Secret**

### Step 2: Generate a Grant Token

1. In the Self Client, click **Generate Code**
2. Enter the required scopes:
   ```
   ZohoBigin.modules.ALL,ZohoBigin.settings.ALL,ZohoBigin.org.READ
   ```
3. Set a description, choose your portal, and click **Create**
4. Copy the generated code (valid for ~3 minutes)

### Step 3: Exchange for Refresh Token

```bash
curl -X POST "https://accounts.zoho.eu/oauth/v2/token" \
  -d "grant_type=authorization_code" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "code=YOUR_GRANT_TOKEN"
```

The response contains your `refresh_token` — save it, it doesn't expire.

### Step 4: Create Credentials File

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

> **Region endpoints:**
>
> | Region | Token Endpoint | API Base |
> |--------|---------------|----------|
> | EU | `https://accounts.zoho.eu/oauth/v2/token` | `https://www.zohoapis.eu/bigin/v2` |
> | US | `https://accounts.zoho.com/oauth/v2/token` | `https://www.zohoapis.com/bigin/v2` |
> | IN | `https://accounts.zoho.in/oauth/v2/token` | `https://www.zohoapis.in/bigin/v2` |
> | AU | `https://accounts.zoho.com.au/oauth/v2/token` | `https://www.zohoapis.com.au/bigin/v2` |

The CLI will auto-refresh the `access_token` on first use.

### Step 5: Generate Your Map

```bash
bash scripts/bigin.sh map
```

This creates `bigin-map.json` with your org's pipelines, stages, sub-pipelines, and field definitions.

## Usage

### Read Operations (no flags needed)

```bash
# Search deals by keyword
bash scripts/bigin.sh deals "Acme Corp"

# Search deals by stage
bash scripts/bigin.sh deals --stage "Qualified"

# Get a single deal
bash scripts/bigin.sh deal <deal_id>

# Search contacts
bash scripts/bigin.sh contacts "Smith"

# Search accounts (companies)
bash scripts/bigin.sh accounts "Google"

# List notes for a record
bash scripts/bigin.sh notes Pipelines <deal_id>

# List all products
bash scripts/bigin.sh products

# View your org's modules, fields, or metadata
bash scripts/bigin.sh modules
bash scripts/bigin.sh fields Pipelines
bash scripts/bigin.sh org
```

### Write Operations (require `BIGIN_WRITE=1`)

```bash
# Add a note
BIGIN_WRITE=1 bash scripts/bigin.sh note Pipelines <deal_id> "Call Summary" "Discussed pricing."

# Move deal to a new stage
BIGIN_WRITE=1 bash scripts/bigin.sh move <deal_id> "Won"

# Update record fields
BIGIN_WRITE=1 bash scripts/bigin.sh update Pipelines <deal_id> '{"Amount": 15000}'

# Create a new contact
BIGIN_WRITE=1 bash scripts/bigin.sh create Contacts '{"First_Name":"Jane","Last_Name":"Doe","Email":"jane@example.com"}'
```

### Delete Operations (require `BIGIN_WRITE=1 BIGIN_CONFIRM=1`)

```bash
BIGIN_WRITE=1 BIGIN_CONFIRM=1 bash scripts/bigin.sh delete Contacts <id>
```

### Raw API Access

```bash
# Read (no flags)
bash scripts/bigin.sh raw GET "/Pipelines?fields=Deal_Name,Stage&per_page=10"

# Write (requires BIGIN_WRITE=1)
BIGIN_WRITE=1 bash scripts/bigin.sh raw PUT "/Pipelines/<id>" '{"data":[{"Stage":"Won"}]}'
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BIGIN_CREDS_FILE` | `~/.bigin-oauth.json` | Path to OAuth credentials |
| `BIGIN_MAP_FILE` | `<script_dir>/../bigin-map.json` | Path to metadata cache |
| `BIGIN_WRITE` | `0` | Set to `1` to enable write operations |
| `BIGIN_CONFIRM` | `0` | Set to `1` to enable destructive operations |

## Bigin Concepts

| Bigin Term | Meaning |
|-----------|---------|
| Pipelines | Deals — the main module API name |
| Accounts | Companies |
| Sub_Pipeline | The pipeline category (e.g., "Sales", "Support") |
| Stage | The deal stage within a pipeline |
| Layout | Groups of stages and sub-pipelines |

> **Important:** Bigin is NOT full Zoho CRM. Some CRM features (COQL, certain scopes) are not available.

## Date Formats

Bigin expects dates as `YYYY-MM-DD` (e.g., `2026-03-15`). DateTime fields use ISO 8601.
Do NOT use locale formats like `DD.MM.YYYY` or `March 15, 2026`.

## Error Handling

- **429/5xx**: Auto-retry with exponential backoff (3 attempts)
- **Token expired**: Auto-refresh and retry
- **Invalid stage**: Validated against `bigin-map.json` with fuzzy matching
- **Invalid JSON**: Validated before API call

All errors output structured JSON to stderr:

```json
{"success": false, "error_code": "WRITE_BLOCKED", "message": "...", "retryable": false}
```

## AI Agent Integration

This CLI is designed for use by AI agents (Claude, GPT, etc.). The `skills/bigin/SKILL.md` file provides agent-friendly documentation with trigger words, anti-patterns, and module mappings.

To use as a skill in an agent framework:
1. Point the agent to `skills/bigin/SKILL.md`
2. Let the agent call `bash scripts/bigin.sh <command>` via shell tool
3. The guardrails prevent accidental mutations — the agent must explicitly set `BIGIN_WRITE=1`

## Tests

Run the smoke tests (no API calls required):

```bash
bash tests/test.sh
```

## License

MIT — see [LICENSE](LICENSE).
