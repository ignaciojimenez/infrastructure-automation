#!/bin/bash
set -e
set -o pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Log with timestamp and color
log_msg() {
	echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_msg "${GREEN}Starting Pi-hole update${NC}"

if sudo pihole -up; then
	log_msg "${GREEN}Pi-hole update completed successfully${NC}"
	echo "✅ Pi-hole update completed successfully"
	exit 0
else
	log_msg "${RED}Pi-hole update failed with exit code $?${NC}"
	echo "❌ Pi-hole update failed"
	exit 1
fi
