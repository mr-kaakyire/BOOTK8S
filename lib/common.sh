#!/bin/bash
# =============================================================================
# common.sh — Shared logging helpers, run_step, and LOG_FILE
# Sourced by all other lib files and the main script
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/k8s-setup.log"

log_info()    { echo -e "${BLUE}[→]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }

run_step() {
    local description="$1"
    local command="$2"

    echo -ne "  ${BLUE}[-]${NC} ${description}..."
    if eval "$command" >> "$LOG_FILE" 2>&1; then
        echo -e "\r  ${GREEN}[✓]${NC} ${description}"
    else
        echo -e "\r  ${RED}[✗]${NC} ${description}"
        log_error "Failed at: ${description}"
        log_error "See $LOG_FILE for details"
        exit 1
    fi
}
