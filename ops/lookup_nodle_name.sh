#!/usr/bin/env bash
# Look up Nodle / Click name service records via the production indexer.
#
# Returns owned names, owners, and linked social handles (com.x / com.twitter).
#
# Usage:
#   lookup_nodle_name.sh --address 0x98f3f23798deaa759ad1d5334a1c1d6acb87b717
#   lookup_nodle_name.sh --name girlnext.nodl.eth
#   lookup_nodle_name.sh --name girlnext
#
# Environment (optional):
#   N_INDEXER_URL      default: https://indexer.nodleprotocol.io
#   N_NODLE_NS_ADDR    default: 0x9741565272C7B29574c88ed2eBDF15BFE9C04612
#   N_CLICK_NS_ADDR    default: 0xF3271B61291C128F9dA5aB208311d8CF8E2Ba5A9
#
# Requirements: curl, jq, python3

set -euo pipefail

INDEXER_URL="${N_INDEXER_URL:-https://indexer.nodleprotocol.io}"
NODLE_NS_ADDR="${N_NODLE_NS_ADDR:-0x9741565272C7B29574c88ed2eBDF15BFE9C04612}"
CLICK_NS_ADDR="${N_CLICK_NS_ADDR:-0xF3271B61291C128F9dA5aB208311d8CF8E2Ba5A9}"

usage() {
  echo "Usage: $0 --address <0x...> | --name <name|name.nodl.eth|name.clk.eth>" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

query_indexer() {
  local payload="$1"
  curl -sS -X POST "$INDEXER_URL" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

normalize_address() {
  python3 -c 'import sys; print(sys.argv[1].lower())' "$1"
}

normalize_name() {
  python3 -c 'import sys; print(sys.argv[1].lower())' "$1"
}

social_handle() {
  local records_json="$1"
  local handle
  handle="$(echo "$records_json" | jq -r '
    [.[] | select(.key == "com.x" or .key == "com.twitter") | .value]
    | map(select(length > 0))
    | if length > 0 then .[0] else "" end
  ')"
  if [ -z "$handle" ]; then
    echo "(none)"
  else
    echo "$handle"
  fi
}

print_ens_nodes() {
  local nodes_json="$1"
  local count
  count="$(echo "$nodes_json" | jq 'length')"

  if [ "$count" -eq 0 ]; then
    echo "No matching names found."
    return 0
  fi

  echo "$nodes_json" | jq -c '.[]' | while read -r node; do
    local complete_name owner contract records social
    complete_name="$(echo "$node" | jq -r '.completeName')"
    owner="$(echo "$node" | jq -r '.ownerId // empty')"
    contract="$(echo "$node" | jq -r '.contract // empty')"
    records="$(echo "$node" | jq -c '.textRecords.nodes // []')"
    social="$(social_handle "$records")"

    echo "Name:     $complete_name"
    if [ -n "$owner" ]; then
      echo "Owner:    $owner"
    fi
    if [ -n "$contract" ]; then
      echo "Contract: $contract"
    fi
    echo "X handle: $social"
    echo
  done
}

lookup_by_address() {
  local address
  address="$(normalize_address "$1")"

  local query payload response nodes
  query="$(cat <<EOF
{
  "query": "{ account(id: \"$address\") { id name primaryName eNsByOwnerId { nodes { name completeName contract ownerId textRecords { nodes { key value } } } } } }"
}
EOF
)"
  payload="$query"
  response="$(query_indexer "$payload")"

  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    echo "Indexer error:" >&2
    echo "$response" | jq '.errors' >&2
    exit 1
  fi

  local account
  account="$(echo "$response" | jq '.data.account')"
  if [ "$account" = "null" ]; then
    echo "No account found for address: $address" >&2
    echo "Tip: indexer account ids must be lowercase." >&2
    exit 1
  fi

  echo "Address:     $address"
  echo "Primary:     $(echo "$account" | jq -r '.primaryName // "(none)"')"
  echo

  nodes="$(echo "$account" | jq '.eNsByOwnerId.nodes')"
  print_ens_nodes "$nodes"
}

lookup_by_name() {
  local raw_name complete_name bare_name domain_filter payload response nodes

  raw_name="$(normalize_name "$1")"

  if [[ "$raw_name" == *.* ]]; then
    complete_name="$raw_name"
    query="$(cat <<EOF
{
  "query": "{ eNs(filter: { completeName: { equalTo: \"$complete_name\" } }, first: 10) { nodes { name completeName contract ownerId textRecords { nodes { key value } } } } }"
}
EOF
)"
  else
    bare_name="$raw_name"
  query="$(cat <<EOF
{
  "query": "{ eNs(filter: { name: { equalTo: \"$bare_name\" } }, first: 10) { nodes { name completeName contract ownerId textRecords { nodes { key value } } } } }"
}
EOF
)"
  fi

  payload="$query"
  response="$(query_indexer "$payload")"

  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    echo "Indexer error:" >&2
    echo "$response" | jq '.errors' >&2
    exit 1
  fi

  nodes="$(echo "$response" | jq '.data.eNs.nodes')"
  print_ens_nodes "$nodes"
}

require_cmd curl
require_cmd jq
require_cmd python3

MODE=""
VALUE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --address|-a)
      MODE="address"
      VALUE="${2:-}"
      shift 2
      ;;
    --name|-n)
      MODE="name"
      VALUE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ -z "$MODE" ] || [ -z "$VALUE" ]; then
  usage
fi

case "$MODE" in
  address)
    lookup_by_address "$VALUE"
    ;;
  name)
    lookup_by_name "$VALUE"
    ;;
esac
