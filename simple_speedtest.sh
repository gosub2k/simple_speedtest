#!/bin/bash

# SSH Speed Test Script
# Tests upload and download speeds through an SSH connection

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
TEST_SIZE_MB=100
SSH_HOST=""
SSH_PORT=""
SSH_USER=""
USE_COMPRESSION=false
USE_CONFIG_ALIAS=false
DATA_SOURCE="mixed"  # Options: random, zero, mixed

usage() {
    echo "Usage: $0 [-p PORT] [-u USER] [-s SIZE_MB] [-c] [-d DATA_TYPE] HOST"
    echo ""
    echo "Options:"
    echo "  -h HOST       SSH host or alias from ~/.ssh/config (required)"
    echo "  -p PORT       SSH port (optional, uses config if not specified)"
    echo "  -u USER       SSH username (optional, uses config if not specified)"
    echo "  -s SIZE_MB    Test file size in MB (default: 100)"
    echo "  -c            Enable SSH compression (default: disabled)"
    echo "  -d DATA_TYPE  Data type: random, zero, mixed (default: mixed)"
    echo "                - random: incompressible random data (/dev/urandom)"
    echo "                - zero: highly compressible zeros (/dev/zero)"
    echo "                - mixed: realistic mix (~50% compressible text-like data)"
    echo ""
    echo "Examples:"
    echo "  $0 -h example.com"
    echo "  $0 -h my-server  # Uses alias from ~/.ssh/config"
    echo "  $0 -h example.com -p 2222 -u myuser -s 50"
    echo "  $0 -h example.com -c  # Test with compression enabled"
    echo "  $0 -h example.com -c -d mixed  # Test compression on realistic data"
    exit 1
}

# Parse arguments
while getopts "p:u:s:d:c" opt; do
    case $opt in
        p) SSH_PORT="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        s) TEST_SIZE_MB="$OPTARG" ;;
        d) DATA_SOURCE="$OPTARG" ;;
        c) USE_COMPRESSION=true ;;
        *) usage ;;
    esac
done

SSH_HOST=$1
if [ -z "$SSH_HOST" ]; then
    echo -e "${RED}Error: SSH host is required${NC}"
    usage
elif [[ $# != 1 ]]; then
    usage
fi

# Validate data source
if [[ ! "$DATA_SOURCE" =~ ^(random|zero|mixed)$ ]]; then
    echo -e "${RED}Error: Invalid data source '$DATA_SOURCE'. Must be: random, zero, or mixed${NC}"
    exit 1
fi

# Build SSH connection string and SCP flags
# If port or user are not specified, let SSH use config
if [ -z "$SSH_PORT" ] && [ -z "$SSH_USER" ]; then
    # Likely using SSH config alias
    SSH_CONN="$SSH_HOST"
    SCP_PORT_FLAG=""
    SSH_PORT_FLAG=""
    USE_CONFIG_ALIAS=true
elif [ -z "$SSH_USER" ]; then
    # Port specified but not user
    SSH_CONN="$SSH_HOST"
    SCP_PORT_FLAG="-P $SSH_PORT"
    SSH_PORT_FLAG="-p $SSH_PORT"
elif [ -z "$SSH_PORT" ]; then
    # User specified but not port
    SSH_CONN="${SSH_USER}@${SSH_HOST}"
    SCP_PORT_FLAG=""
    SSH_PORT_FLAG=""
else
    # Both specified
    SSH_CONN="${SSH_USER}@${SSH_HOST}"
    SCP_PORT_FLAG="-P $SSH_PORT"
    SSH_PORT_FLAG="-p $SSH_PORT"
fi

# Set compression flags
if [ "$USE_COMPRESSION" = true ]; then
    SCP_COMPRESS_FLAG="-C"
    COMPRESSION_STATUS="enabled"
else
    SCP_COMPRESS_FLAG="-o Compression=no"
    COMPRESSION_STATUS="disabled"
fi

echo -e "${GREEN}=== SSH Connection Speed Test ===${NC}"
echo "Host: $SSH_HOST"
if [ "$USE_CONFIG_ALIAS" = true ]; then
    echo "Using SSH config for connection details"
else
    [ -n "$SSH_PORT" ] && echo "Port: $SSH_PORT"
    [ -n "$SSH_USER" ] && echo "User: $SSH_USER"
fi
echo "Test size: ${TEST_SIZE_MB}MB"
echo "Data type: $DATA_SOURCE"
echo "Compression: $COMPRESSION_STATUS"
echo ""

# Test SSH connection first
echo -e "${YELLOW}Testing SSH connection...${NC}"
if ! ssh $SSH_PORT_FLAG -o ConnectTimeout=10 -o BatchMode=yes "$SSH_CONN" "echo 'Connection successful'" 2>/dev/null; then
    echo -e "${RED}Error: Cannot connect to SSH host${NC}"
    echo "Make sure:"
    echo "  1. The host is reachable"
    echo "  2. SSH keys are set up (passwordless login)"
    echo "  3. Port and username are correct (or SSH config is properly configured)"
    exit 1
fi
echo -e "${GREEN}✓ Connection successful${NC}"
echo ""

# Create temporary test file
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

echo -e "${YELLOW}Generating ${TEST_SIZE_MB}MB test file ($DATA_SOURCE)...${NC}"

case "$DATA_SOURCE" in
    random)
        # Pure random data - doesn't compress at all
        dd if=/dev/urandom of="$TEMP_FILE" bs=1M count="$TEST_SIZE_MB" 2>/dev/null
        ;;
    zero)
        # Pure zeros - compresses extremely well
        dd if=/dev/zero of="$TEMP_FILE" bs=1M count="$TEST_SIZE_MB" 2>/dev/null
        ;;
    mixed)
        # Realistic mix: some compressible text, some binary data
        # Approximately 50% compressible - simulates real-world files
        HALF_SIZE=$((TEST_SIZE_MB / 2))

        # First half: text-like data (compressible)
        # Using base64 of zeros creates ASCII text that compresses moderately well
        dd if=/dev/zero bs=1M count="$HALF_SIZE" 2>/dev/null | base64 > "$TEMP_FILE"

        # Second half: random data (incompressible)
        dd if=/dev/urandom bs=1M count="$HALF_SIZE" 2>/dev/null >> "$TEMP_FILE"

        # Truncate to exact size in case base64 made it larger
        truncate -s "${TEST_SIZE_MB}M" "$TEMP_FILE"
        ;;
esac

echo -e "${GREEN}✓ Test file created${NC}"
echo ""

# Test upload speed
echo -e "${YELLOW}Testing UPLOAD speed...${NC}"
UPLOAD_START=$(date +%s.%N)
set -x
scp $SCP_COMPRESS_FLAG $SCP_PORT_FLAG -q "$TEMP_FILE" "${SSH_CONN}:/tmp/ssh_speed_test_$$" 2>/dev/null
set +x
UPLOAD_END=$(date +%s.%N)
UPLOAD_TIME=$(echo "$UPLOAD_END - $UPLOAD_START" | bc)
UPLOAD_SPEED=$(echo "scale=2; ($TEST_SIZE_MB * 8) / $UPLOAD_TIME" | bc)
echo -e "${GREEN}✓ Upload completed${NC}"
echo "  Time: ${UPLOAD_TIME}s"
echo "  Speed: ${UPLOAD_SPEED} Mbps"
echo ""

# Test download speed
echo -e "${YELLOW}Testing DOWNLOAD speed...${NC}"
DOWNLOAD_START=$(date +%s.%N)
set -x
scp $SCP_COMPRESS_FLAG $SCP_PORT_FLAG -q "${SSH_CONN}:/tmp/ssh_speed_test_$$" "$TEMP_FILE.download" 2>/dev/null
set +x
DOWNLOAD_END=$(date +%s.%N)
DOWNLOAD_TIME=$(echo "$DOWNLOAD_END - $DOWNLOAD_START" | bc)
DOWNLOAD_SPEED=$(echo "scale=2; ($TEST_SIZE_MB * 8) / $DOWNLOAD_TIME" | bc)
echo -e "${GREEN}✓ Download completed${NC}"
echo "  Time: ${DOWNLOAD_TIME}s"
echo "  Speed: ${DOWNLOAD_SPEED} Mbps"
echo ""

# Clean up remote file
ssh $SSH_PORT_FLAG "$SSH_CONN" "rm -f /tmp/ssh_speed_test_$$" 2>/dev/null
rm -f "$TEMP_FILE.download"

# Summary
echo -e "${GREEN}=== Summary ===${NC}"
echo "Upload:   ${UPLOAD_SPEED} Mbps (${UPLOAD_TIME}s)"
echo "Download: ${DOWNLOAD_SPEED} Mbps (${DOWNLOAD_TIME}s)"

# Calculate average
AVG_SPEED=$(echo "scale=2; ($UPLOAD_SPEED + $DOWNLOAD_SPEED) / 2" | bc)
echo "Average:  ${AVG_SPEED} Mbps"
