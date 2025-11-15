#!/bin/bash
# Vinylstreamer Audio Services Health Monitor

set -euo pipefail

# Configuration
LOG_FILE="$HOME/.log/vinylstreamer_monitor.log"
ACTIONS_TAKEN=""

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check audio detection service
check_audio_detection() {
    if systemctl is-active --quiet detect_audio; then
        log_message "✅ Audio detection service is running"
        return 0
    else
        log_message "❌ Audio detection service is not running"
        
        # Try to start the service
        log_message "🔄 Attempting to start audio detection service"
        if sudo systemctl start detect_audio; then
            log_message "✅ Successfully started audio detection service"
            ACTIONS_TAKEN="${ACTIONS_TAKEN}Started detect_audio; "
            return 0
        else
            log_message "❌ Failed to start audio detection service"
            return 1
        fi
    fi
}

# Function to check Liquidsoap service
check_liquidsoap_service() {
    local service_name="phono_liquidsoap.service"
    if systemctl is-active --quiet "$service_name"; then
        log_message "✅ Liquidsoap service is running"
        return 0
    else
        log_message "❌ Liquidsoap service is not running"
        
        # Try to start the service
        log_message "🔄 Attempting to start Liquidsoap service"
        if sudo systemctl start "$service_name"; then
            log_message "✅ Successfully started Liquidsoap service"
            ACTIONS_TAKEN="${ACTIONS_TAKEN}Started liquidsoap; "
            return 0
        else
            log_message "❌ Failed to start Liquidsoap service"
            return 1
        fi
    fi
}

# Function to check Icecast2 service
check_icecast_service() {
    if systemctl is-active --quiet icecast2; then
        log_message "✅ Icecast2 service is running"
        return 0
    else
        log_message "❌ Icecast2 service is not running"
        
        # Try to start the service
        log_message "🔄 Attempting to start Icecast2 service"
        if sudo systemctl start icecast2; then
            log_message "✅ Successfully started Icecast2 service"
            ACTIONS_TAKEN="${ACTIONS_TAKEN}Started icecast2; "
            return 0
        else
            log_message "❌ Failed to start Icecast2 service"
            return 1
        fi
    fi
}

# Function to check audio hardware
check_audio_hardware() {
    if arecord -l | grep -q "card [0-9]"; then
        local audio_info=$(arecord -l | grep -E '^card [0-9]+:' | head -1)
        log_message "✅ Audio hardware detected: $audio_info"
        return 0
    else
        log_message "❌ No audio hardware detected"
        return 1
    fi
}

# Function to check ALSA configuration
check_alsa_config() {
    if [ -f /etc/asound.conf ]; then
        log_message "✅ ALSA configuration file exists"
        return 0
    else
        log_message "❌ ALSA configuration file missing"
        return 1
    fi
}

# Function to check streaming endpoint
check_streaming_endpoint() {
    local icecast_port=8000
    local timeout=10
    
    if timeout $timeout bash -c "echo >/dev/tcp/localhost/$icecast_port" 2>/dev/null; then
        log_message "✅ Icecast streaming endpoint is accessible on port $icecast_port"
        return 0
    else
        log_message "❌ Icecast streaming endpoint is not accessible on port $icecast_port"
        return 1
    fi
}

# Function to check system resources
check_system_resources() {
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
    local mem_usage=$(free | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100.0}')
    local temp_celsius=0
    
    # Check temperature if available
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp_celsius=$((temp / 1000))
    fi
    
    log_message "📊 System resources: CPU: ${cpu_usage}%, Memory: ${mem_usage}%, Temp: ${temp_celsius}°C"
    
    # Check for concerning resource usage
    local issues=0
    
    if (( $(echo "$mem_usage > 85" | bc -l) )); then
        log_message "⚠️  High memory usage: ${mem_usage}%"
        issues=$((issues + 1))
    fi
    
    if [ "$temp_celsius" -gt 75 ]; then
        log_message "⚠️  High temperature: ${temp_celsius}°C"
        issues=$((issues + 1))
    fi
    
    if [ $issues -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Function to check stream connectivity
check_stream_connected() {
    local stream_url="http://localhost:8000/status-json.xsl"
    
    if curl -s "$stream_url" | grep -q '"source"'; then
        log_message "✅ Audio stream is connected to Icecast"
        return 0
    else
        log_message "❌ No audio stream connected to Icecast"
        return 1
    fi
}

# Function to check log files for errors
check_log_errors() {
    local error_count=0
    
    # Check detect_audio logs
    if [ -f "$HOME/.log/detect_audio.log" ]; then
        local recent_errors=$(tail -100 "$HOME/.log/detect_audio.log" | grep -i error | wc -l)
        if [ "$recent_errors" -gt 5 ]; then
            log_message "⚠️  Found $recent_errors recent errors in detect_audio.log"
            error_count=$((error_count + recent_errors))
        fi
    fi
    
    # Check icecast logs
    if [ -f /var/log/icecast2/error.log ]; then
        local recent_errors=$(tail -100 /var/log/icecast2/error.log | grep -i error | wc -l)
        if [ "$recent_errors" -gt 5 ]; then
            log_message "⚠️  Found $recent_errors recent errors in icecast2 error.log"
            error_count=$((error_count + recent_errors))
        fi
    fi
    
    if [ $error_count -eq 0 ]; then
        log_message "✅ No significant errors found in log files"
        return 0
    else
        log_message "❌ Found $error_count total errors in log files"
        return 1
    fi
}

# Main monitoring logic
main() {
    log_message "🎵 Starting Vinylstreamer health check"
    
    local failed_checks=0
    local total_checks=0
    
    # Check audio hardware
    total_checks=$((total_checks + 1))
    if ! check_audio_hardware; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check ALSA configuration
    total_checks=$((total_checks + 1))
    if ! check_alsa_config; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check audio detection service
    total_checks=$((total_checks + 1))
    if ! check_audio_detection; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check Liquidsoap service
    total_checks=$((total_checks + 1))
    if ! check_liquidsoap_service; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check Icecast2 service
    total_checks=$((total_checks + 1))
    if ! check_icecast_service; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check stream connectivity
    total_checks=$((total_checks + 1))
    if ! check_stream_connected; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check streaming endpoint
    total_checks=$((total_checks + 1))
    if ! check_streaming_endpoint; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check system resources
    total_checks=$((total_checks + 1))
    if ! check_system_resources; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Check log files for errors
    total_checks=$((total_checks + 1))
    if ! check_log_errors; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Report results
    if [ $failed_checks -eq 0 ]; then
        log_message "✅ All Vinylstreamer checks passed ($total_checks checks)"
        if [ -n "$ACTIONS_TAKEN" ]; then
            echo "ACTIONS TAKEN: $ACTIONS_TAKEN"
        fi
        exit 0
    else
        log_message "❌ $failed_checks out of $total_checks checks failed"
        if [ -n "$ACTIONS_TAKEN" ]; then
            echo "ACTIONS TAKEN: $ACTIONS_TAKEN"
        fi
        exit 1
    fi
}

# Run main function
main "$@"
