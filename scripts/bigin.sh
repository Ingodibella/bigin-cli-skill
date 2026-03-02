#!/usr/bin/env bash
# bigin.sh — Zoho Bigin REST API CLI
#
# Usage: bigin.sh <command> [args...]
#
# CRUD Commands:
#   get <module> <id>                     Get single record
#   list <module> [--fields F] [--limit N] List records
#   search <module> <field> <value>       Search records (criteria)
#   create <module> <json>                Create record (WRITE MODE)
#   update <module> <id> <json>           Update record (WRITE MODE)
#   delete <module> <id>                  Delete record (WRITE MODE, CONFIRM)
#
# Deal Commands:
#   deals [query] [--stage X] [--limit N]   List/search deals
#   deal <id>                                Get deal details
#   move <deal_id> <stage> [--layout X]      Move deal to stage (WRITE MODE, validated)
#
# Note Commands:
#   note <module> <id> <title> <text>     Add note to record (WRITE MODE)
#   notes <module> <id>                   List notes for record
#
# Lookup Commands:
#   contacts [query]                      Search or list contacts
#   accounts [query]                      Search or list accounts
#   products [deal_id]                    List products (or deal products)
#
# Meta Commands:
#   map                                   Generate Bigin map (pipelines/stages/fields)
#   fields <module>                       List fields for module
#   modules                               List all modules
#   org                                   Show organization details
#   raw <GET|POST|PUT|DELETE> <path> [body]  Raw API call (GET=read, others=WRITE MODE)
#
# Config: $BIGIN_CREDS_FILE or ~/.bigin-oauth.json
# Auto-refreshes expired tokens. Read-only by default.
#
# GUARDRAILS:
#   - Read-only by default
#   - Write ops (create, update, delete, move, note, raw POST/PUT) require BIGIN_WRITE=1
#   - Delete ops (delete, raw DELETE) require BIGIN_CONFIRM=1 additionally
#   - move validates stage against bigin-map.json
#   - create/update validate JSON input
#   - Set: BIGIN_WRITE=1 bigin.sh update ...
#
# Environment:
#   BIGIN_CREDS_FILE  Path to OAuth credentials JSON (default: ~/.bigin-oauth.json)
#   BIGIN_MAP_FILE    Path to Bigin map cache (default: <script_dir>/../bigin-map.json)
#   BIGIN_WRITE       Set to 1 to enable write operations
#   BIGIN_CONFIRM     Set to 1 to enable destructive operations (requires BIGIN_WRITE=1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="${BIGIN_CREDS_FILE:-$HOME/.bigin-oauth.json}"
MAP_FILE="${BIGIN_MAP_FILE:-${SCRIPT_DIR}/../bigin-map.json}"
BIGIN_WRITE="${BIGIN_WRITE:-0}"
BIGIN_CONFIRM="${BIGIN_CONFIRM:-0}"
MAX_RETRIES=3
RETRY_DELAY=2

# ── Structured Output ─────────────────────────────────────────────

_error() {
  local code="$1" message="$2" retryable="${3:-false}"
  jq -nc --arg c "$code" --arg m "$message" --arg r "$retryable" \
    '{success: false, error_code: $c, message: $m, retryable: ($r == "true")}' >&2
  exit 1
}

# ── Guardrails ────────────────────────────────────────────────────

require_write() {
  if [[ "$BIGIN_WRITE" != "1" ]]; then
    _error "WRITE_BLOCKED" "Write operations require BIGIN_WRITE=1. Example: BIGIN_WRITE=1 bigin.sh update ..."
  fi
}

require_confirm() {
  require_write
  if [[ "$BIGIN_CONFIRM" != "1" ]]; then
    _error "CONFIRM_REQUIRED" "Destructive operations require BIGIN_CONFIRM=1. Example: BIGIN_WRITE=1 BIGIN_CONFIRM=1 bigin.sh delete ..."
  fi
}

validate_json() {
  local data="$1" label="${2:-input}"
  if ! echo "$data" | jq -e . >/dev/null 2>&1; then
    _error "INVALID_JSON" "Malformed JSON in $label"
  fi
}

# ── Token Management ──────────────────────────────────────────────

load_config() {
  if [[ ! -f "$CREDS_FILE" ]]; then
    _error "CONFIG_MISSING" "Credentials not found: $CREDS_FILE. See README for setup."
  fi
  chmod 600 "$CREDS_FILE" 2>/dev/null || true
  CLIENT_ID=$(jq -r '.client_id' "$CREDS_FILE")
  CLIENT_SECRET=$(jq -r '.client_secret' "$CREDS_FILE")
  ACCESS_TOKEN=$(jq -r '.access_token' "$CREDS_FILE")
  REFRESH_TOKEN=$(jq -r '.refresh_token' "$CREDS_FILE")
  TOKEN_ENDPOINT=$(jq -r '.token_endpoint // "https://accounts.zoho.eu/oauth/v2/token"' "$CREDS_FILE")
  API_BASE=$(jq -r '.api_base // "https://www.zohoapis.eu/bigin/v2"' "$CREDS_FILE")
  EXPIRES_AT=$(jq -r '.expires_at // "0"' "$CREDS_FILE")
}

save_token() {
  local new_token="$1" new_expires="$2"
  local tmp; tmp=$(mktemp)
  jq --arg t "$new_token" --arg e "$new_expires" \
    '.access_token = $t | .expires_at = ($e | tonumber)' "$CREDS_FILE" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE" 2>/dev/null || true
}

refresh_token() {
  local response
  response=$(curl -sS -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$REFRESH_TOKEN" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" 2>&1)

  local new_token
  new_token=$(echo "$response" | jq -r '.access_token // empty')
  if [[ -z "$new_token" ]]; then
    _error "TOKEN_REFRESH_FAILED" "Could not refresh token. Check credentials." "true"
  fi

  local expires_in
  expires_in=$(echo "$response" | jq -r '.expires_in // 3600')
  local new_expires=$(( $(date +%s) + expires_in - 60 ))

  save_token "$new_token" "$new_expires"
  ACCESS_TOKEN="$new_token"
  EXPIRES_AT="$new_expires"
}

ensure_token() {
  local now; now=$(date +%s)
  if [[ "$EXPIRES_AT" == "0" ]] || [[ "$now" -ge "$EXPIRES_AT" ]]; then
    refresh_token
  fi
}

# ── HTTP with Retry ───────────────────────────────────────────────

_curl() {
  local method="$1" path="$2" body="${3:-}"
  ensure_token

  local attempt=0 response http_code
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    if [[ -n "$body" ]]; then
      response=$(curl -sS -w "\n%{http_code}" -X "$method" "${API_BASE}${path}" \
        -H "Authorization: Zoho-oauthtoken $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body" 2>&1)
    else
      response=$(curl -sS -w "\n%{http_code}" -X "$method" "${API_BASE}${path}" \
        -H "Authorization: Zoho-oauthtoken $ACCESS_TOKEN" 2>&1)
    fi

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    case "$http_code" in
      429|500|502|503|504)
        attempt=$((attempt + 1))
        if [[ $attempt -lt $MAX_RETRIES ]]; then
          sleep $((RETRY_DELAY * attempt))
          continue
        fi
        ;;
      *)
        break
        ;;
    esac
  done

  echo "$response"
}

_curl_search() {
  local path="$1"
  shift
  ensure_token

  local attempt=0 response http_code
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    response=$(curl -sS -w "\n%{http_code}" -G "${API_BASE}${path}" \
      "$@" \
      -H "Authorization: Zoho-oauthtoken $ACCESS_TOKEN" 2>&1)

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    case "$http_code" in
      429|500|502|503|504)
        attempt=$((attempt + 1))
        if [[ $attempt -lt $MAX_RETRIES ]]; then
          sleep $((RETRY_DELAY * attempt))
          continue
        fi
        ;;
      *)
        break
        ;;
    esac
  done

  echo "$response"
}

api_get()    { _curl GET "$1"; }
api_post()   { _curl POST "$1" "$2"; }
api_put()    { _curl PUT "$1" "$2"; }
api_delete() { _curl DELETE "$1"; }

# ── Stage Validation ──────────────────────────────────────────────

validate_stage() {
  local stage_name="$1"
  local layout_name="${2:-}"

  if [[ ! -f "$MAP_FILE" ]]; then
    echo "Map not found, generating..." >&2
    cmd_map >/dev/null 2>&1
    if [[ ! -f "$MAP_FILE" ]]; then
      _error "MAP_MISSING" "Could not generate bigin-map.json. Run: bigin.sh map"
    fi
  fi

  local match
  if [[ -n "$layout_name" ]]; then
    match=$(python3 -c "
import json, sys
map_file, stage, layout = sys.argv[1], sys.argv[2], sys.argv[3]
with open(map_file) as f:
    m = json.load(f)
for l in m.get('layouts', []):
    if l['name'].lower() == layout.lower():
        for s in l.get('stages', []):
            if s['name'] == stage:
                print(s['name'])
                sys.exit(0)
        for s in l.get('stages', []):
            if s['name'].lower() == stage.lower():
                print(s['name'])
                sys.exit(0)
        print('STAGE_NOT_IN_LAYOUT')
        sys.exit(1)
print('LAYOUT_NOT_FOUND')
sys.exit(1)
" "$MAP_FILE" "$stage_name" "$layout_name" 2>/dev/null) || true
  else
    match=$(python3 -c "
import json, sys
map_file, stage = sys.argv[1], sys.argv[2]
with open(map_file) as f:
    m = json.load(f)
seen = set()
matches = []
for l in m.get('layouts', []):
    for s in l.get('stages', []):
        key = s['name']
        if key == stage and key not in seen:
            matches.append((key, l['name']))
            seen.add(key)
        elif key.lower() == stage.lower() and key not in seen:
            matches.append((key, l['name']))
            seen.add(key)
if len(matches) == 1:
    print(matches[0][0])
elif len(matches) > 1:
    layouts = ', '.join(m[1] for m in matches)
    print(f'AMBIGUOUS:{layouts}')
else:
    print('NOT_FOUND')
" "$MAP_FILE" "$stage_name" 2>/dev/null)
  fi

  case "$match" in
    STAGE_NOT_IN_LAYOUT)
      _error "INVALID_STAGE" "Stage not found in layout. Run: bigin.sh map to see valid stages."
      ;;
    LAYOUT_NOT_FOUND)
      _error "INVALID_LAYOUT" "Layout not found. Run: bigin.sh map to see available layouts."
      ;;
    NOT_FOUND)
      _error "INVALID_STAGE" "Stage not found in any layout. Run: bigin.sh map to see valid stages."
      ;;
    AMBIGUOUS:*)
      local layouts="${match#AMBIGUOUS:}"
      _error "AMBIGUOUS_STAGE" "Stage exists in multiple layouts: $layouts. Use --layout to specify."
      ;;
    *)
      echo "$match"
      ;;
  esac
}

# ── Module field defaults ─────────────────────────────────────────

default_fields() {
  local module="$1"
  case "$module" in
    Pipelines)  echo "Deal_Name,Stage,Amount,Pipeline,Sub_Pipeline,Contact_Name,Account_Name,Closing_Date,Tag" ;;
    Contacts)   echo "First_Name,Last_Name,Email,Phone,Account_Name" ;;
    Accounts)   echo "Account_Name,Website,Phone" ;;
    Products)   echo "Product_Name,Unit_Price,Product_Code" ;;
    Tasks)      echo "Subject,Status,Due_Date,Priority" ;;
    Events)     echo "Event_Title,Start_DateTime,End_DateTime" ;;
    Notes)      echo "Note_Title,Note_Content,Parent_Id" ;;
    *)          echo "" ;;
  esac
}

# ── Commands ──────────────────────────────────────────────────────

cmd_get() {
  local module="${1:?Usage: bigin.sh get <module> <id>}"
  local id="${2:?Usage: bigin.sh get <module> <id>}"
  local fields; fields=$(default_fields "$module")
  if [[ -n "$fields" ]]; then
    api_get "/$module/$id?fields=$fields"
  else
    api_get "/$module/$id"
  fi
}

cmd_list() {
  local module="${1:?Usage: bigin.sh list <module>}"
  shift
  local limit=50 fields=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --fields) fields="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$fields" ]] && fields=$(default_fields "$module")
  if [[ -n "$fields" ]]; then
    api_get "/$module?fields=$fields&per_page=$limit"
  else
    api_get "/$module?per_page=$limit"
  fi
}

cmd_search() {
  local module="${1:?Usage: bigin.sh search <module> <field> <value>}"
  local field="${2:?Usage: bigin.sh search <module> <field> <value>}"
  local value="${3:?Usage: bigin.sh search <module> <field> <value>}"
  local fields; fields=$(default_fields "$module")
  _curl_search "/$module/search" \
    --data-urlencode "criteria=(${field}:equals:${value})" \
    ${fields:+--data-urlencode "fields=$fields"}
}

cmd_create() {
  require_write
  local module="${1:?Usage: bigin.sh create <module> <json>}"
  local data="${2:?Usage: bigin.sh create <module> <json>}"
  validate_json "$data" "create data"
  local payload
  payload=$(jq -n --argjson d "$data" '{data: (if ($d | type) == "array" then $d else [$d] end)}')
  api_post "/$module" "$payload"
}

cmd_update() {
  require_write
  local module="${1:?Usage: bigin.sh update <module> <id> <json>}"
  local id="${2:?Usage: bigin.sh update <module> <id> <json>}"
  local data="${3:?Usage: bigin.sh update <module> <id> <json>}"
  validate_json "$data" "update data"
  local payload
  payload=$(jq -n --argjson d "$data" '{data: (if ($d | type) == "array" then $d else [$d] end)}')
  api_put "/$module/$id" "$payload"
}

cmd_delete() {
  require_confirm
  local module="${1:?Usage: bigin.sh delete <module> <id>}"
  local id="${2:?Usage: bigin.sh delete <module> <id>}"
  api_delete "/$module/$id?wf_trigger=true"
}

cmd_deals() {
  local query="" stage="" limit=200 fields="Deal_Name,Stage,Amount,Pipeline,Sub_Pipeline,Contact_Name,Account_Name,Closing_Date,Tag"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sub|--query|-q) query="$2"; shift 2 ;;
      --stage) stage="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --fields) fields="$2"; shift 2 ;;
      *) query="$1"; shift ;;
    esac
  done

  if [[ -n "$query" ]]; then
    _curl_search "/Pipelines/search" \
      --data-urlencode "word=$query" \
      --data-urlencode "fields=$fields" \
      --data-urlencode "per_page=$limit"
  elif [[ -n "$stage" ]]; then
    _curl_search "/Pipelines/search" \
      --data-urlencode "criteria=(Stage:equals:$stage)" \
      --data-urlencode "fields=$fields" \
      --data-urlencode "per_page=$limit"
  else
    api_get "/Pipelines?fields=${fields}&per_page=${limit}"
  fi
}

cmd_deal() {
  local id="${1:?Usage: bigin.sh deal <id>}"
  api_get "/Pipelines/$id?fields=Deal_Name,Stage,Amount,Pipeline,Sub_Pipeline,Contact_Name,Account_Name,Closing_Date,Tag,Description,Created_Time,Modified_Time,Last_Activity_Time"
}

cmd_move() {
  require_write
  local deal_id="" stage="" layout=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --layout) layout="$2"; shift 2 ;;
      *)
        if [[ -z "$deal_id" ]]; then
          deal_id="$1"
        elif [[ -z "$stage" ]]; then
          stage="$1"
        fi
        shift
        ;;
    esac
  done

  [[ -z "$deal_id" ]] && _error "MISSING_PARAM" "Usage: bigin.sh move <deal_id> <stage> [--layout <name>]"
  [[ -z "$stage" ]] && _error "MISSING_PARAM" "Usage: bigin.sh move <deal_id> <stage> [--layout <name>]"

  # Validate stage against map (layout-specific if given, otherwise global)
  local validated_stage
  validated_stage=$(validate_stage "$stage" "$layout")

  local payload
  payload=$(jq -n --arg s "$validated_stage" '{data: [{Stage: $s}]}')
  api_put "/Pipelines/$deal_id" "$payload"
}

cmd_note() {
  require_write
  local module="${1:?Usage: bigin.sh note <module> <id> <title> <text>}"
  local id="${2:?Usage: bigin.sh note <module> <id> <title> <text>}"
  local title="${3:?Usage: bigin.sh note <module> <id> <title> <text>}"
  shift 3
  local text="$*"
  local payload
  payload=$(jq -n --arg t "$title" --arg c "$text" '{data: [{Note_Title: $t, Note_Content: $c}]}')
  api_post "/$module/$id/Notes" "$payload"
}

cmd_notes() {
  local module="${1:?Usage: bigin.sh notes <module> <id>}"
  local id="${2:?Usage: bigin.sh notes <module> <id>}"
  api_get "/$module/$id/Notes?fields=Note_Title,Note_Content,Created_Time,Created_By&per_page=20"
}

cmd_contacts() {
  local query="${1:-}"
  if [[ -n "$query" ]]; then
    _curl_search "/Contacts/search" \
      --data-urlencode "word=$query" \
      --data-urlencode "fields=First_Name,Last_Name,Email,Phone,Account_Name,Title"
  else
    api_get "/Contacts?fields=First_Name,Last_Name,Email,Phone,Account_Name&per_page=50"
  fi
}

cmd_accounts() {
  local query="${1:-}"
  if [[ -n "$query" ]]; then
    _curl_search "/Accounts/search" \
      --data-urlencode "word=$query" \
      --data-urlencode "fields=Account_Name,Website,Phone"
  else
    api_get "/Accounts?fields=Account_Name,Website,Phone&per_page=50"
  fi
}

cmd_products() {
  local deal_id="${1:-}"
  if [[ -n "$deal_id" ]]; then
    api_get "/Pipelines/$deal_id/Products"
  else
    api_get "/Products?fields=Product_Name,Unit_Price,Product_Code&per_page=50"
  fi
}

cmd_modules() {
  api_get "/settings/modules"
}

cmd_fields() {
  local module="${1:?Usage: bigin.sh fields <module>}"
  api_get "/settings/fields?module=$module"
}

cmd_org() {
  api_get "/org"
}

cmd_map() {
  ensure_token
  echo "Generating Bigin map..." >&2

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf \"$tmpdir\"" EXIT

  api_get "/org" > "$tmpdir/org.json"
  api_get "/settings/modules" > "$tmpdir/modules.json"
  api_get "/settings/layouts?module=Pipelines" > "$tmpdir/layouts.json"
  api_get "/settings/fields?module=Pipelines" > "$tmpdir/pipeline_fields.json"
  api_get "/settings/fields?module=Contacts" > "$tmpdir/contact_fields.json"
  api_get "/settings/fields?module=Accounts" > "$tmpdir/account_fields.json"
  api_get "/settings/fields?module=Products" > "$tmpdir/product_fields.json"

  python3 - "$tmpdir" "$MAP_FILE" "$API_BASE" << 'PYEOF'
import json, sys, os
from datetime import datetime

tmpdir = sys.argv[1]
map_file = sys.argv[2]
api_base = sys.argv[3]

def load(name):
    with open(os.path.join(tmpdir, name)) as f:
        return json.load(f)

org_data = load("org.json")
modules = load("modules.json")
layouts = load("layouts.json")
pf = load("pipeline_fields.json")
cf = load("contact_fields.json")
af = load("account_fields.json")
prodf = load("product_fields.json")

# Extract org name dynamically
org_list = org_data.get("org", [])
org_name = org_list[0].get("company_name", "Unknown") if org_list else "Unknown"

bigin_map = {
    "generated_at": datetime.now().isoformat(),
    "org": org_name,
    "api_base": api_base,
    "modules": [],
    "layouts": [],
    "stages": {},
    "sub_pipelines": {},
    "fields": {}
}

for m in modules.get("modules", []):
    bigin_map["modules"].append({
        "api_name": m.get("api_name"),
        "display": m.get("module_name"),
        "plural": m.get("plural_label")
    })

for layout in layouts.get("layouts", []):
    l = {"name": layout.get("name"), "id": layout.get("id"), "stages": [], "sub_pipelines": []}
    for section in layout.get("sections", []):
        for field in section.get("fields", []):
            if field.get("api_name") == "Stage":
                for pv in field.get("pick_list_values", []):
                    stage = {"name": pv.get("display_value"), "id": pv.get("id")}
                    l["stages"].append(stage)
                    bigin_map["stages"][pv.get("id")] = {
                        "name": pv.get("display_value"),
                        "layouts": bigin_map["stages"].get(pv.get("id"), {}).get("layouts", []) + [layout.get("name")]
                    }
            elif field.get("api_name") == "Sub_Pipeline":
                for pv in field.get("pick_list_values", []):
                    sp = {"name": pv.get("display_value"), "id": pv.get("id")}
                    l["sub_pipelines"].append(sp)
                    bigin_map["sub_pipelines"][pv.get("id")] = {
                        "name": pv.get("display_value"),
                        "layouts": bigin_map["sub_pipelines"].get(pv.get("id"), {}).get("layouts", []) + [layout.get("name")]
                    }
    bigin_map["layouts"].append(l)

def extract_fields(raw):
    out = []
    for f in raw.get("fields", []):
        entry = {
            "api_name": f.get("api_name"),
            "type": f.get("data_type"),
            "label": f.get("display_label"),
            "read_only": f.get("read_only", False)
        }
        if f.get("pick_list_values"):
            entry["values"] = [v.get("display_value") for v in f["pick_list_values"] if v.get("display_value") != "-None-"]
        out.append(entry)
    return out

bigin_map["fields"]["Pipelines"] = extract_fields(pf)
bigin_map["fields"]["Contacts"] = extract_fields(cf)
bigin_map["fields"]["Accounts"] = extract_fields(af)
bigin_map["fields"]["Products"] = extract_fields(prodf)

output = json.dumps(bigin_map, indent=2, ensure_ascii=False)
print(output)

os.makedirs(os.path.dirname(map_file), exist_ok=True)
with open(map_file, "w") as f:
    f.write(output)
PYEOF

  echo "" >&2
  echo "Map saved to $MAP_FILE" >&2
}

cmd_raw() {
  local method="${1:?Usage: bigin.sh raw <GET|POST|PUT|DELETE> <path> [body]}"
  local path="${2:?Usage: bigin.sh raw <method> <path> [body]}"
  local body="${3:-}"
  method=$(echo "$method" | tr '[:lower:]' '[:upper:]')
  case "$method" in
    GET)    api_get "$path" ;;
    POST)   require_write; api_post "$path" "$body" ;;
    PUT)    require_write; api_put "$path" "$body" ;;
    DELETE) require_confirm; api_delete "$path" ;;
    *)      _error "INVALID_METHOD" "Unknown HTTP method: $method" ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────

load_config

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
  get)        cmd_get "$@" ;;
  list)       cmd_list "$@" ;;
  search)     cmd_search "$@" ;;
  create)     cmd_create "$@" ;;
  update)     cmd_update "$@" ;;
  delete)     cmd_delete "$@" ;;
  deals)      cmd_deals "$@" ;;
  deal)       cmd_deal "$@" ;;
  move)       cmd_move "$@" ;;
  note)       cmd_note "$@" ;;
  notes)      cmd_notes "$@" ;;
  contacts)   cmd_contacts "$@" ;;
  accounts)   cmd_accounts "$@" ;;
  products)   cmd_products "$@" ;;
  modules)    cmd_modules ;;
  fields)     cmd_fields "$@" ;;
  org)        cmd_org ;;
  map)        cmd_map ;;
  raw)        cmd_raw "$@" ;;
  help|--help|-h)
    sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    ;;
  *)
    _error "UNKNOWN_COMMAND" "Unknown command: $CMD. Run: bigin.sh help"
    ;;
esac
