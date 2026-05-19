#!/bin/bash

# Guardant Key Health Check Script
# Periodically checks Guardant USB key availability and maintains connection
# Occupies component sessions during key access to prevent conflicts

# Configuration variables (can be overridden via environment variables or command line)
CHECK_INTERVAL=${GUARDANT_CHECK_INTERVAL:-30}  # Check interval in seconds (default: 30)
MAX_CLIENTS=${GUARDANT_MAX_CLIENTS:-5}        # Max parallel clients for checking (default: 5)
LOG_FILE=${GUARDANT_LOG_FILE:-/var/log/guardant_health.log}
LOCK_FILE="/tmp/guardant_health.lock"
SESSION_TIMEOUT=${GUARDANT_SESSION_TIMEOUT:-10}  # Session timeout in seconds

# Component session management
OCCUPY_SESSIONS=${GUARDANT_OCCUPY_SESSIONS:-true}  # Whether to occupy component sessions
SESSION_COMPONENTS=${GUARDANT_SESSION_COMPONENTS:-"certificate,key,container"}  # Components to occupy sessions for

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    case $level in
        "INFO")
            echo -e "${GREEN}[$level]${NC} $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[$level]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[$level]${NC} $message"
            ;;
        *)
            echo "[$level] $message"
            ;;
    esac
}

# Function to check if Guardant tools are available
check_prerequisites() {
    local guardant_tool=""
    
    # Try to find Guardant command-line tools
    if command -v gtt &> /dev/null; then
        guardant_tool="gtt"
    elif command -v guardant-cli &> /dev/null; then
        guardant_tool="guardant-cli"
    elif command -v gc_cli &> /dev/null; then
        guardant_tool="gc_cli"
    elif command -v gcli &> /dev/null; then
        guardant_tool="gcli"
    elif [ -x "/usr/bin/gtt" ] || [ -x "/usr/local/bin/gtt" ]; then
        guardant_tool="gtt"
    fi
    
    if [ -z "$guardant_tool" ]; then
        log_message "WARNING" "Guardant command-line tools not found in PATH. Trying alternative methods."
        return 1
    fi
    
    echo "$guardant_tool"
    return 0
}

# Function to occupy component sessions on the Guardant key
occupy_component_sessions() {
    if [ "$OCCUPY_SESSIONS" != "true" ]; then
        log_message "INFO" "Session occupation is disabled"
        return 0
    fi
    
    log_message "INFO" "${BLUE}Occupying component sessions for: $SESSION_COMPONENTS${NC}"
    
    local session_pids=()
    local components_array
    IFS=',' read -ra components_array <<< "$SESSION_COMPONENTS"
    
    for component in "${components_array[@]}"; do
        component=$(echo "$component" | xargs)  # Trim whitespace
        log_message "INFO" "Opening session for component: $component"
        
        (
            # Create a subshell that holds the session open
            case $component in
                "certificate"|"cert")
                    # Open certificate session using gcli or gtt
                    if command -v gcli &> /dev/null; then
                        timeout "$SESSION_TIMEOUT" gcli cert list > /dev/null 2>&1 &
                    elif command -v gtt &> /dev/null; then
                        timeout "$SESSION_TIMEOUT" gtt -c > /dev/null 2>&1 &
                    fi
                    ;;
                "key"|"privatekey")
                    # Open key/session for cryptographic operations
                    if command -v gcli &> /dev/null; then
                        timeout "$SESSION_TIMEOUT" gcli key list > /dev/null 2>&1 &
                    elif command -v gtt &> /dev/null; then
                        timeout "$SESSION_TIMEOUT" gtt -k > /dev/null 2>&1 &
                    fi
                    ;;
                "container"|"cont")
                    # Open container session
                    if command -v gcli &> /dev/null; then
                        timeout "$SESSION_TIMEOUT" gcli container list > /dev/null 2>&1 &
                    elif command -v gc_cli &> /dev/null; then
                        timeout "$SESSION_TIMEOUT" gc_cli list > /dev/null 2>&1 &
                    fi
                    ;;
                *)
                    log_message "WARNING" "Unknown component type: $component"
                    ;;
            esac
        ) &
        session_pids+=($!)
        log_message "INFO" "Session PID for $component: $!"
    done
    
    # Store PIDs for cleanup
    export GUARDANT_SESSION_PIDS="${session_pids[*]}"
    
    log_message "INFO" "${BLUE}Component sessions occupied successfully${NC}"
    return 0
}

# Function to release occupied sessions
release_component_sessions() {
    if [ -n "$GUARDANT_SESSION_PIDS" ]; then
        log_message "INFO" "Releasing occupied component sessions..."
        for pid in $GUARDANT_SESSION_PIDS; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                log_message "INFO" "Released session PID: $pid"
            fi
        done
        unset GUARDANT_SESSION_PIDS
    fi
}

# Function to check Guardant key using various methods
check_guardant_key() {
    local method=$1
    local result=1
    
    case $method in
        "gtt")
            # Try Guardant Token Tester (gtt) - common for Guardant Sign
            if command -v gtt &> /dev/null; then
                # Run gtt with timeout, try to list tokens
                timeout 10 gtt -l &> /dev/null && result=0
            fi
            ;;
        "usb")
            # Check via USB subsystem
            if command -v lsusb &> /dev/null; then
                if lsusb | grep -i "guardant\|aladdin" &> /dev/null; then
                    result=0
                fi
            fi
            ;;
        "device")
            # Check for Guardant device files
            if [ -e "/dev/bus/usb" ] && ls -la /dev/bus/usb/*/* 2>/dev/null | grep -i guardant &> /dev/null; then
                result=0
            fi
            # Also check for hidraw devices that might be Guardant
            if [ -d "/sys/class/hidraw" ]; then
                for device in /sys/class/hidraw/*; do
                    if [ -f "$device/device/manufacturer" ] && \
                       grep -qi "guardant\|aladdin" "$device/device/manufacturer" 2>/dev/null; then
                        result=0
                        break
                    fi
                done
            fi
            ;;
        "library")
            # Try to load Guardant library and check (if libguardant is available)
            if [ -f "/usr/lib/libguardant.so" ] || [ -f "/usr/lib64/libguardant.so" ]; then
                # Create a simple test program or use existing tool
                if command -v gcli &> /dev/null; then
                    timeout 10 gcli info &> /dev/null && result=0
                fi
            fi
            ;;
    esac
    
    return $result
}

# Function to extract and display Guardant key information
get_guardant_key_info() {
    local info_output=""
    
    log_message "INFO" "Retrieving Guardant key information..."
    
    # Try gtt (Guardant Token Tester) with verbose output
    if command -v gtt &> /dev/null; then
        log_message "INFO" "Querying key via gtt..."
        local gtt_output=$(timeout 10 gtt -v 2>&1 || timeout 10 gtt -l 2>&1 || echo "gtt query failed")
        if [ -n "$gtt_output" ] && [ "$gtt_output" != "gtt query failed" ]; then
            info_output+="=== GTT Output ===\n$gtt_output\n\n"
        fi
    fi
    
    # Try gcli (Guardant CLI) for detailed info
    if command -v gcli &> /dev/null; then
        log_message "INFO" "Querying key via gcli..."
        local gcli_output=$(timeout 10 gcli info 2>&1 || timeout 10 gcli list 2>&1 || echo "gcli query failed")
        if [ -n "$gcli_output" ] && [ "$gcli_output" != "gcli query failed" ]; then
            info_output+="=== GCLI Output ===\n$gcli_output\n\n"
        fi
    fi
    
    # Try gc_cli if available
    if command -v gc_cli &> /dev/null; then
        log_message "INFO" "Querying key via gc_cli..."
        local gc_cli_output=$(timeout 10 gc_cli info 2>&1 || echo "gc_cli query failed")
        if [ -n "$gc_cli_output" ] && [ "$gc_cli_output" != "gc_cli query failed" ]; then
            info_output+="=== GC_CLI Output ===\n$gc_cli_output\n\n"
        fi
    fi
    
    # Get USB device details
    log_message "INFO" "Querying USB subsystem..."
    local usb_info=$(lsusb -v 2>/dev/null | grep -A 20 -i "guardant\\|aladdin" || lsusb 2>/dev/null | grep -i "guardant\\|aladdin" || echo "No USB Guardant info")
    if [ -n "$usb_info" ]; then
        info_output+="=== USB Device Info ===\n$usb_info\n\n"
    fi
    
    # Check for device serial numbers or identifiers
    if [ -d "/sys/class/hidraw" ]; then
        log_message "INFO" "Checking HIDRAW devices..."
        for device in /sys/class/hidraw/*; do
            if [ -f "$device/device/manufacturer" ]; then
                local manufacturer=$(cat "$device/device/manufacturer" 2>/dev/null || echo "")
                local product=$(cat "$device/device/product" 2>/dev/null || echo "")
                local serial=$(cat "$device/device/serial" 2>/dev/null || echo "N/A")
                
                if [[ "$manufacturer" =~ [Gg]uardant ]] || [[ "$manufacturer" =~ [Aa]laddin ]]; then
                    info_output+="=== HIDRAW Device: $device ===\n"
                    info_output+="  Manufacturer: $manufacturer\n"
                    info_output+="  Product: $product\n"
                    info_output+="  Serial: $serial\n\n"
                fi
            fi
        done
    fi
    
    # Check for Guardant library version if available
    if [ -f "/usr/lib/libguardant.so" ] || [ -f "/usr/lib64/libguardant.so" ]; then
        local lib_path="/usr/lib/libguardant.so"
        [ -f "/usr/lib64/libguardant.so" ] && lib_path="/usr/lib64/libguardant.so"
        log_message "INFO" "Guardant library found: $lib_path"
        info_output+="=== Guardant Library ===\nPath: $lib_path\nVersion: $(strings "$lib_path" 2>/dev/null | grep -i "version\\|guardant" | head -5 || echo "Unknown")\n\n"
    fi
    
    # Output collected information
    if [ -n "$info_output" ]; then
        echo -e "$info_output"
        log_message "INFO" "Key information retrieved successfully"
        return 0
    else
        log_message "WARNING" "Could not retrieve detailed key information"
        return 1
    fi
}

# Comprehensive key check using multiple methods
perform_key_check() {
    local check_passed=false
    local methods=("gtt" "usb" "device" "library")
    
    log_message "INFO" "Starting Guardant key check..."
    
    # First try command-line tools
    local guardant_tool=$(check_prerequisites)
    if [ $? -eq 0 ] && [ -n "$guardant_tool" ]; then
        log_message "INFO" "Using Guardant tool: $guardant_tool"
        if check_guardant_key "$guardant_tool"; then
            check_passed=true
        fi
    fi
    
    # If primary method failed, try alternative methods
    if [ "$check_passed" = false ]; then
        for method in "${methods[@]}"; do
            if [ "$method" != "$guardant_tool" ]; then
                log_message "INFO" "Trying alternative method: $method"
                if check_guardant_key "$method"; then
                    log_message "INFO" "Key detected via method: $method"
                    check_passed=true
                    break
                fi
            fi
        done
    fi
    
    if [ "$check_passed" = true ]; then
        log_message "INFO" "✓ Guardant key is accessible and responding"
        
        # Occupy component sessions to prevent conflicts with other applications
        occupy_component_sessions
        
        # Retrieve and display key information
        log_message "INFO" "========================================="
        log_message "INFO" "GUARDANT KEY INFORMATION:"
        log_message "INFO" "========================================="
        local key_info=$(get_guardant_key_info)
        if [ -n "$key_info" ]; then
            echo "$key_info" | while IFS= read -r line; do
                log_message "INFO" "$line"
            done
        fi
        log_message "INFO" "========================================="
        
        # Release occupied sessions after information retrieval
        release_component_sessions
        
        return 0
    else
        log_message "ERROR" "✗ Guardant key is NOT accessible"
        return 1
    fi
}

# Function to simulate multiple clients accessing the key
simulate_clients() {
    local num_clients=$1
    local pids=()
    
    log_message "INFO" "Simulating $num_clients client(s) accessing Guardant key..."
    
    for ((i=1; i<=num_clients; i++)); do
        (
            log_message "INFO" "Client $i: Attempting to access Guardant key..."
            if perform_key_check > /dev/null 2>&1; then
                log_message "INFO" "Client $i: Successfully accessed key"
                exit 0
            else
                log_message "ERROR" "Client $i: Failed to access key"
                exit 1
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all clients to complete
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            ((failed++))
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log_message "WARNING" "$failed out of $num_clients client(s) failed to access the key"
        return 1
    else
        log_message "INFO" "All $num_clients client(s) successfully accessed the key"
        return 0
    fi
}

# Cleanup function
cleanup() {
    log_message "INFO" "Received termination signal. Cleaning up..."
    # Release any occupied sessions before exit
    release_component_sessions
    rm -f "$LOCK_FILE"
    exit 0
}

# Main monitoring loop
main_loop() {
    local iteration=0
    
    log_message "INFO" "========================================="
    log_message "INFO" "Guardant Key Health Monitor Started"
    log_message "INFO" "Check Interval: ${CHECK_INTERVAL}s"
    log_message "INFO" "Max Clients: ${MAX_CLIENTS}"
    log_message "INFO" "Log File: ${LOG_FILE}"
    log_message "INFO" "========================================="
    
    # Set up signal handlers
    trap cleanup SIGINT SIGTERM
    
    # Check for lock file to prevent multiple instances
    if [ -f "$LOCK_FILE" ]; then
        local old_pid=$(cat "$LOCK_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log_message "ERROR" "Another instance is already running (PID: $old_pid)"
            exit 1
        else
            log_message "WARNING" "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    
    while true; do
        ((iteration++))
        log_message "INFO" "--- Check Iteration #$iteration ---"
        
        # Perform key check with simulated clients
        if ! simulate_clients "$MAX_CLIENTS"; then
            log_message "WARNING" "Guardant key accessibility check failed!"
            log_message "INFO" "Attempting to reinitialize connection..."
            
            # Try to reinitialize USB subsystem (optional, may require root)
            if [ "$(id -u)" -eq 0 ]; then
                log_message "INFO" "Attempting USB bus rescan (requires root)..."
                # This might help in some cases
                echo 1 > /sys/bus/usb/drivers/usb/rebind 2>/dev/null || true
            fi
            
            sleep 5
            
            # Retry check
            if ! perform_key_check; then
                log_message "ERROR" "Guardant key remains inaccessible after retry"
                log_message "WARNING" "Application may switch to demo mode!"
            fi
        fi
        
        log_message "INFO" "Sleeping for ${CHECK_INTERVAL}s before next check..."
        sleep "$CHECK_INTERVAL"
    done
}

# Show usage information
show_usage() {
    cat << EOF
Guardant Key Health Check Script

Usage: $0 [OPTIONS]

Options:
    -i, --interval SECONDS          Check interval in seconds (default: 30)
    -c, --clients NUMBER            Number of clients to simulate (default: 5)
    -l, --log FILE                  Log file path (default: /var/log/guardant_health.log)
    -h, --help                      Show this help message
    -t, --test                      Run single test and exit
    -s, --session-timeout SECONDS   Session timeout for component occupation (default: 10)
        --occupy-sessions BOOL      Occupy component sessions during check (default: true)
        --session-components LIST   Comma-separated list of components to occupy 
                                    (default: certificate,key,container)

Environment Variables:
    GUARDANT_CHECK_INTERVAL         Check interval in seconds
    GUARDANT_MAX_CLIENTS            Maximum number of clients
    GUARDANT_LOG_FILE               Log file path
    GUARDANT_SESSION_TIMEOUT        Session timeout in seconds
    GUARDANT_OCCUPY_SESSIONS        Whether to occupy sessions (true/false)
    GUARDANT_SESSION_COMPONENTS     Components to occupy (comma-separated)

Component Types:
    certificate, cert    - Certificate session
    key, privatekey      - Cryptographic key session  
    container, cont      - Container session

Examples:
    $0                                  # Run with defaults
    $0 -i 60 -c 3                       # Check every 60s with 3 clients
    $0 --interval 120                   # Check every 2 minutes
    $0 --occupy-sessions false          # Disable session occupation
    $0 --session-components cert,key    # Only occupy cert and key sessions
    GUARDANT_CHECK_INTERVAL=45 $0       # Using environment variable
    GUARDANT_OCCUPY_SESSIONS=false $0   # Disable via env variable

EOF
}

# Parse command line arguments
parse_args() {
    local test_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -c|--clients)
                MAX_CLIENTS="$2"
                shift 2
                ;;
            -l|--log)
                LOG_FILE="$2"
                shift 2
                ;;
            -s|--session-timeout)
                SESSION_TIMEOUT="$2"
                shift 2
                ;;
            --occupy-sessions)
                OCCUPY_SESSIONS="$2"
                shift 2
                ;;
            --session-components)
                SESSION_COMPONENTS="$2"
                shift 2
                ;;
            -t|--test)
                test_mode=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_message "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate parameters
    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$CHECK_INTERVAL" -lt 1 ]; then
        log_message "ERROR" "Invalid interval: must be a positive integer"
        exit 1
    fi
    
    if ! [[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] || [ "$MAX_CLIENTS" -lt 1 ]; then
        log_message "ERROR" "Invalid clients count: must be a positive integer"
        exit 1
    fi
    
    if ! [[ "$SESSION_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SESSION_TIMEOUT" -lt 1 ]; then
        log_message "ERROR" "Invalid session timeout: must be a positive integer"
        exit 1
    fi
    
    # Validate occupy sessions boolean
    if [[ "$OCCUPY_SESSIONS" != "true" && "$OCCUPY_SESSIONS" != "false" ]]; then
        log_message "ERROR" "Invalid occupy-sessions value: must be 'true' or 'false'"
        exit 1
    fi
    
    if [ "$test_mode" = true ]; then
        log_message "INFO" "Running single test mode..."
        perform_key_check
        exit $?
    fi
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    
    # Create log directory if it doesn't exist
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            echo "Warning: Cannot create log directory $log_dir, using /tmp"
            LOG_FILE="/tmp/guardant_health.log"
        }
    fi
    
    # Check if we can write to log file
    touch "$LOG_FILE" 2>/dev/null || {
        echo "Warning: Cannot write to $LOG_FILE, using /tmp"
        LOG_FILE="/tmp/guardant_health.log"
    }
    
    main_loop
fi
