#!/bin/bash
# run-checkpoints.sh - Run mechanical checkpoint verification
# Part of extension-assessment skill
#
# Usage: run-checkpoints.sh <checkpoint-file.yaml> <project-root>
#
# Reads checkpoint definitions from YAML (new schema with mechanical: section)
# and runs scripted checks. Outputs JSON report with pass/fail status.
#
# Schema version: 1
# Expected format:
#   version: 1
#   skill_id: my-skill
#   mechanical:
#     - id: XX-01
#       type: file_exists
#       target: README.md
#       severity: error
#       desc: "..."
#   llm_reviews:
#     - ... (skipped by this script)

set -euo pipefail

CHECKPOINT_FILE="${1:-}"
PROJECT_ROOT="${2:-.}"

if [[ -z "$CHECKPOINT_FILE" ]]; then
    echo "Usage: $0 <checkpoint-file.yaml> <project-root>" >&2
    exit 1
fi

if [[ ! -f "$CHECKPOINT_FILE" ]]; then
    echo "Error: Checkpoint file not found: $CHECKPOINT_FILE" >&2
    exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "Error: Project root not found: $PROJECT_ROOT" >&2
    exit 1
fi

cd "$PROJECT_ROOT"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Results array
declare -a RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SKILL_ID=""

# Parse checkpoint file and run checks
run_checkpoint() {
    local id="$1"
    local type="$2"
    local target="$3"
    local pattern="${4:-}"
    local severity="${5:-error}"
    local desc="${6:-}"

    local status="skip"
    local evidence=""

    case "$type" in
        file_exists)
            if [[ -f "$target" ]]; then
                status="pass"
                evidence="File exists: $target"
            else
                status="fail"
                evidence="File not found: $target"
            fi
            ;;
        file_not_exists)
            if [[ ! -f "$target" ]]; then
                status="pass"
                evidence="File correctly absent: $target"
            else
                status="fail"
                evidence="File should not exist: $target"
            fi
            ;;
        contains)
            if [[ -f "$target" ]] && grep -q "$pattern" "$target" 2>/dev/null; then
                status="pass"
                evidence="Pattern found in $target"
            elif [[ ! -f "$target" ]]; then
                status="fail"
                evidence="Target file not found: $target"
            else
                status="fail"
                evidence="Pattern not found in $target"
            fi
            ;;
        not_contains)
            if [[ -f "$target" ]] && ! grep -q "$pattern" "$target" 2>/dev/null; then
                status="pass"
                evidence="Pattern correctly absent from $target"
            elif [[ ! -f "$target" ]]; then
                status="pass"
                evidence="Target file not found (OK for not_contains): $target"
            else
                status="fail"
                evidence="Pattern should not be in $target"
            fi
            ;;
        regex)
            # Handle glob patterns in target
            local files=()
            if [[ "$target" == *"*"* ]]; then
                # Glob pattern - expand it
                shopt -s nullglob
                files=($target)
                shopt -u nullglob
            else
                files=("$target")
            fi

            local found=false
            for f in "${files[@]}"; do
                if [[ -f "$f" ]] && grep -qE "$pattern" "$f" 2>/dev/null; then
                    found=true
                    evidence="Pattern found in $f"
                    break
                fi
            done

            if $found; then
                status="pass"
            else
                if [[ ${#files[@]} -eq 0 ]]; then
                    status="fail"
                    evidence="No files match glob pattern: $target"
                else
                    status="fail"
                    evidence="Pattern not found in $target"
                fi
            fi
            ;;
        json_path)
            if [[ -f "$target" ]] && jq -e "$pattern" "$target" > /dev/null 2>&1; then
                status="pass"
                evidence="JSON path exists in $target"
            elif [[ ! -f "$target" ]]; then
                status="fail"
                evidence="Target file not found: $target"
            else
                status="fail"
                evidence="JSON path not found in $target"
            fi
            ;;
        gh_api)
            # Skip GitHub API checks in scripted mode - need auth context
            status="skip"
            evidence="GitHub API checks require interactive mode"
            ;;
        command)
            if eval "$pattern" > /dev/null 2>&1; then
                status="pass"
                evidence="Command succeeded"
            else
                status="fail"
                evidence="Command failed"
            fi
            ;;
        *)
            status="skip"
            evidence="Unknown checkpoint type: $type"
            ;;
    esac

    # Update counts
    case "$status" in
        pass) ((PASS_COUNT++)) || true ;;
        fail) ((FAIL_COUNT++)) || true ;;
        skip) ((SKIP_COUNT++)) || true ;;
    esac

    # Terminal output
    case "$status" in
        pass) echo -e "${GREEN}✓${NC} [$id] $desc" ;;
        fail) echo -e "${RED}✗${NC} [$id] $desc - $evidence" ;;
        skip) echo -e "${YELLOW}○${NC} [$id] $desc - SKIPPED" ;;
    esac

    # Escape quotes in evidence for JSON
    evidence="${evidence//\"/\\\"}"

    # Add to results
    RESULTS+=("{\"id\":\"$id\",\"status\":\"$status\",\"severity\":\"$severity\",\"evidence\":\"$evidence\"}")
}

echo "========================================"
echo "Extension Assessment - Scripted Checks"
echo "========================================"
echo "Project: $PROJECT_ROOT"
echo "Checkpoints: $CHECKPOINT_FILE"
echo "----------------------------------------"

# Parse YAML with new schema (mechanical: section)
# Using simple parsing since yq might not be available
current_id=""
current_type=""
current_target=""
current_pattern=""
current_severity="error"
current_desc=""
in_mechanical_section=false
in_llm_section=false

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Detect schema version
    if [[ "$line" =~ ^version:[[:space:]]*([0-9]+)$ ]]; then
        version="${BASH_REMATCH[1]}"
        if [[ "$version" != "1" ]]; then
            echo -e "${RED}Error: Unsupported schema version: $version${NC}" >&2
            exit 1
        fi
        continue
    fi

    # Extract skill_id
    if [[ "$line" =~ ^skill_id:[[:space:]]*(.+)$ ]]; then
        SKILL_ID="${BASH_REMATCH[1]}"
        echo -e "${BLUE}Skill: $SKILL_ID${NC}"
        continue
    fi

    # Detect section headers
    if [[ "$line" =~ ^mechanical:[[:space:]]*$ ]]; then
        in_mechanical_section=true
        in_llm_section=false
        continue
    fi

    if [[ "$line" =~ ^llm_reviews:[[:space:]]*$ ]]; then
        # Process any pending checkpoint before switching sections
        if [[ -n "$current_id" ]]; then
            run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc"
            current_id=""
        fi
        in_mechanical_section=false
        in_llm_section=true
        continue
    fi

    # Only process lines in mechanical section
    if ! $in_mechanical_section; then
        continue
    fi

    # Parse checkpoint fields
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
        # New checkpoint - process previous if exists
        if [[ -n "$current_id" ]]; then
            run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc"
        fi
        current_id="${BASH_REMATCH[1]}"
        current_type=""
        current_target=""
        current_pattern=""
        current_severity="error"
        current_desc=""
    elif [[ "$line" =~ ^[[:space:]]*type:[[:space:]]*(.+)$ ]]; then
        current_type="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*(.+)$ ]]; then
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*[\"\']*([^\"\']+)[\"\']*$ ]]; then
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*severity:[[:space:]]*(.+)$ ]]; then
        current_severity="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*desc:[[:space:]]*[\"\']*(.+)[\"\']*$ ]]; then
        current_desc="${BASH_REMATCH[1]}"
    fi
done < "$CHECKPOINT_FILE"

# Process last checkpoint if still in mechanical section
if [[ -n "$current_id" ]] && $in_mechanical_section; then
    run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc"
fi

echo "----------------------------------------"
echo -e "Summary: ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, ${YELLOW}$SKIP_COUNT skipped${NC}"
echo "----------------------------------------"

# Output JSON report
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
JSON_RESULTS=$(IFS=,; echo "${RESULTS[*]}")

cat << EOF
{
  "checkpoint_file": "$CHECKPOINT_FILE",
  "project_root": "$PROJECT_ROOT",
  "skill_id": "$SKILL_ID",
  "schema_version": 1,
  "summary": {
    "total": $TOTAL,
    "pass": $PASS_COUNT,
    "fail": $FAIL_COUNT,
    "skip": $SKIP_COUNT
  },
  "checkpoints": [
    $JSON_RESULTS
  ]
}
EOF

# Exit with error if any failures
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
