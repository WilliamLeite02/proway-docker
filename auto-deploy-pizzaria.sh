#!/bin/bash

#######################################
# Pizzaria Auto-Deploy Script
# Automatically installs, deploys and updates the pizzaria application
# Repository: https://github.com/WilliamLeite02/proway-docker.git
# Author: William Leite
#######################################

set -e  # Exit on any error

# Configuration
REPO_URL="https://github.com/WilliamLeite02/proway-docker.git"
PROJECT_DIR="/opt/pizzaria"
LOG_FILE="/var/log/pizzaria-deploy.log"
LOCK_FILE="/tmp/pizzaria-deploy.lock"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#######################################
# Logging function
#######################################
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

#######################################
# Error handling
#######################################
error_exit() {
    log "${RED}ERROR: $1${NC}"
    rm -f "$LOCK_FILE"
    exit 1
}

#######################################
# Check if script is already running
#######################################
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log "${YELLOW}Deploy script is already running (PID: $pid). Exiting.${NC}"
            exit 0
        else
            log "${YELLOW}Removing stale lock file${NC}"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

#######################################
# Install system dependencies
#######################################
install_dependencies() {
    log "${BLUE}Checking and installing system dependencies...${NC}"
    
    # Update package list
    apt-get update -qq
    
    # Install required packages
    local packages=(
        "docker.io"
        "docker-compose"
        "git"
        "curl"
        "cron"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "${YELLOW}Installing $package...${NC}"
            apt-get install -y "$package" || error_exit "Failed to install $package"
        else
            log "${GREEN}$package is already installed${NC}"
        fi
    done
    
    # Start and enable docker service
    systemctl start docker || error_exit "Failed to start docker service"
    systemctl enable docker || error_exit "Failed to enable docker service"
    
    # Add current user to docker group (if not root)
    if [ "$EUID" -ne 0 ] && ! groups | grep -q docker; then
        usermod -aG docker "$USER"
        log "${YELLOW}Added user to docker group. You may need to log out and back in.${NC}"
    fi
}

#######################################
# Check if repository has updates
#######################################
check_for_updates() {
    if [ ! -d "$PROJECT_DIR" ]; then
        return 0  # New installation needed
    fi
    
    cd "$PROJECT_DIR"
    
    # Fetch latest changes from remote
    git fetch origin main 2>/dev/null || git fetch origin master 2>/dev/null || error_exit "Failed to fetch from remote repository"
    
    # Get current local commit and remote commit
    local local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
    local remote_commit=$(git rev-parse @{u} 2>/dev/null || git rev-parse origin/master 2>/dev/null || git rev-parse origin/main 2>/dev/null)
    
    if [ "$local_commit" != "$remote_commit" ]; then
        log "${YELLOW}Updates available. Local: ${local_commit:0:7}, Remote: ${remote_commit:0:7}${NC}"
        return 0
    else
        log "${GREEN}Repository is up to date${NC}"
        return 1
    fi
}

#######################################
# Clone or update repository
#######################################
setup_repository() {
    if [ ! -d "$PROJECT_DIR" ]; then
        log "${BLUE}Cloning repository...${NC}"
        mkdir -p "$(dirname "$PROJECT_DIR")"
        git clone "$REPO_URL" "$PROJECT_DIR" || error_exit "Failed to clone repository"
    else
        log "${BLUE}Updating repository...${NC}"
        cd "$PROJECT_DIR"
        git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || error_exit "Failed to pull latest changes"
    fi
    
    cd "$PROJECT_DIR"
    local current_commit=$(git rev-parse --short HEAD)
    log "${GREEN}Repository updated to commit: $current_commit${NC}"
}

#######################################
# Build and deploy application
#######################################
deploy_application() {
    log "${BLUE}Deploying pizzaria application...${NC}"
    
    cd "$PROJECT_DIR"
    
    # Check if docker-compose.yml exists
    if [ ! -f "$COMPOSE_FILE" ]; then
        error_exit "docker-compose.yml not found in $PROJECT_DIR"
    fi
    
    # Stop existing containers
    if docker-compose ps -q > /dev/null 2>&1; then
        log "${YELLOW}Stopping existing containers...${NC}"
        docker-compose down --remove-orphans || log "${YELLOW}No containers to stop${NC}"
    fi
    
    # Remove old images to ensure rebuild (force rebuild)
    log "${YELLOW}Removing old images to force rebuild...${NC}"
    docker-compose down --rmi all --remove-orphans 2>/dev/null || true
    
    # Clean up unused docker resources
    docker system prune -f 2>/dev/null || true
    
    # Build and start containers with forced rebuild
    log "${BLUE}Building and starting containers (forced rebuild)...${NC}"
    docker-compose build --no-cache --pull || error_exit "Failed to build containers"
    docker-compose up -d || error_exit "Failed to start containers"
    
    # Wait for containers to be healthy
    log "${BLUE}Waiting for containers to start...${NC}"
    sleep 15
    
    # Check if containers are running
    local running_containers=$(docker-compose ps -q | wc -l)
    if [ "$running_containers" -eq 0 ]; then
        error_exit "No containers are running after deployment"
    fi
    
    log "${GREEN}Successfully deployed $running_containers container(s)${NC}"
    
    # Show container status
    docker-compose ps | tee -a "$LOG_FILE"
    
    # Show exposed ports
    log "${BLUE}Checking exposed ports...${NC}"
    docker-compose ps | grep -E ":80->|:3000->|:8080->" | while read line; do
        log "${GREEN}Service accessible: $line${NC}"
    done
    
    # Test if application is responding
    sleep 5
    local frontend_port=$(docker-compose port frontend 3000 2>/dev/null | cut -d: -f2 || echo "")
    local backend_port=$(docker-compose port backend 5000 2>/dev/null | cut -d: -f2 || echo "")
    
    if [ -n "$frontend_port" ]; then
        if curl -s -f http://localhost:$frontend_port > /dev/null 2>&1; then
            log "${GREEN}Frontend is responding on port $frontend_port${NC}"
        else
            log "${YELLOW}Frontend may still be starting on port $frontend_port${NC}"
        fi
    fi
    
    if [ -n "$backend_port" ]; then
        if curl -s -f http://localhost:$backend_port/health 2>/dev/null || curl -s -f http://localhost:$backend_port > /dev/null 2>&1; then
            log "${GREEN}Backend is responding on port $backend_port${NC}"
        else
            log "${YELLOW}Backend may still be starting on port $backend_port${NC}"
        fi
    fi
}

#######################################
# Setup cron job
#######################################
setup_cron() {
    local script_path=$(readlink -f "$0")
    local cron_job="*/5 * * * * $script_path > /dev/null 2>&1"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -F "$script_path" > /dev/null; then
        log "${GREEN}Cron job already exists for this script${NC}"
    else
        log "${BLUE}Setting up cron job to run every 5 minutes...${NC}"
        # Add new cron job to existing crontab
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log "${GREEN}Cron job installed successfully${NC}"
        log "${BLUE}Script will now run automatically every 5 minutes${NC}"
    fi
    
    # Ensure cron service is running
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
}

#######################################
# Show application status
#######################################
show_status() {
    log "${BLUE}=== Pizzaria Application Status ===${NC}"
    
    if [ -d "$PROJECT_DIR" ]; then
        cd "$PROJECT_DIR"
        
        # Show git status
        local current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        local current_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        local last_update=$(git log -1 --format="%cd" --date=short 2>/dev/null || echo "unknown")
        
        log "Git Branch: $current_branch"
        log "Current Commit: $current_commit"
        log "Last Update: $last_update"
        
        # Show docker status
        log "${BLUE}Docker Containers:${NC}"
        if docker-compose ps 2>/dev/null; then
            log "${GREEN}All containers status shown above${NC}"
        else
            log "${RED}No containers found or docker-compose not available${NC}"
        fi
        
        # Show accessible URLs
        log "${BLUE}Accessible URLs:${NC}"
        docker-compose ps 2>/dev/null | grep -E ":.*->" | while read line; do
            local port=$(echo "$line" | grep -o -E "[0-9]+:[0-9]+" | cut -d: -f1)
            if [ -n "$port" ]; then
                log "${GREEN}http://localhost:$port${NC}"
            fi
        done
        
        # Show resource usage
        log "${BLUE}Resource Usage:${NC}"
        docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | head -5 || log "Unable to get resource stats"
        
    else
        log "${RED}Project directory not found at $PROJECT_DIR${NC}"
        log "${YELLOW}Run this script to perform initial setup${NC}"
    fi
}

#######################################
# Clean up function
#######################################
cleanup() {
    rm -f "$LOCK_FILE"
}

#######################################
# Main execution
#######################################
main() {
    log "${BLUE}========================================${NC}"
    log "${BLUE}Starting Pizzaria Auto-Deploy System${NC}"
    log "${BLUE}Repository: $REPO_URL${NC}"
    log "${BLUE}========================================${NC}"
    
    # Set up signal handlers for cleanup
    trap cleanup EXIT INT TERM
    
    # Check for concurrent execution
    check_lock
    
    # Install dependencies (only if missing)
    if ! command -v docker > /dev/null || ! command -v docker-compose > /dev/null; then
        if [ "$EUID" -ne 0 ]; then
            error_exit "Please run as root for initial setup to install dependencies"
        fi
        install_dependencies
    fi
    
    # Check for updates and deploy if needed
    if check_for_updates; then
        setup_repository
        deploy_application
        log "${GREEN}Application updated successfully!${NC}"
    else
        # Even if no updates, check if containers are running
        if [ -d "$PROJECT_DIR" ]; then
            cd "$PROJECT_DIR"
            local running_containers=$(docker-compose ps -q 2>/dev/null | wc -l)
            if [ "$running_containers" -eq 0 ]; then
                log "${YELLOW}No containers running. Starting application...${NC}"
                deploy_application
            else
                log "${GREEN}Application is running and up to date${NC}"
            fi
        else
            log "${YELLOW}Initial setup required${NC}"
            setup_repository
            deploy_application
        fi
    fi
    
    # Setup cron job (always check)
    setup_cron
    
    # Show final status
    show_status
    
    log "${GREEN}========================================${NC}"
    log "${GREEN}Pizzaria Auto-Deploy completed successfully!${NC}"
    log "${GREEN}System will auto-update every 5 minutes${NC}"
    log "${GREEN}========================================${NC}"
}

#######################################
# Help function
#######################################
show_help() {
    echo "Pizzaria Auto-Deploy System"
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -s, --status   Show application status only"
    echo "  -f, --force    Force deployment even if up to date"
    echo ""
    echo "This script will:"
    echo "  1. Install Docker and dependencies"
    echo "  2. Clone/update the pizzaria repository"
    echo "  3. Build and deploy the application"
    echo "  4. Set up automatic updates every 5 minutes"
    echo ""
    echo "Repository: $REPO_URL"
}

#######################################
# Script entry point
#######################################
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -s|--status)
        show_status
        exit 0
        ;;
    -f|--force)
        # Force deployment by skipping update check
        main() {
            log "${BLUE}========================================${NC}"
            log "${BLUE}FORCED Pizzaria Deploy (skipping update check)${NC}"
            log "${BLUE}========================================${NC}"
            
            trap cleanup EXIT INT TERM
            check_lock
            
            if ! command -v docker > /dev/null || ! command -v docker-compose > /dev/null; then
                if [ "$EUID" -ne 0 ]; then
                    error_exit "Please run as root for initial setup"
                fi
                install_dependencies
            fi
            
            setup_repository
            deploy_application
            setup_cron
            show_status
            
            log "${GREEN}FORCED deployment completed!${NC}"
        }
        main
        ;;
    *)
        main "$@"
        ;;
esac
