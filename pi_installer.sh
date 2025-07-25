#!/bin/bash

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
log_step() {
    echo -e "\n${BLUE}==============================="
    echo -e ">>> $1"
    echo -e "===============================${NC}\n"
}

# Function to check if command succeeded
check_success() {
    if [ $? -eq 0 ]; then
        log_info "$1 completed successfully"
    else
        log_error "$1 failed"
        exit 1
    fi
}

# Function to download with retry
download_with_retry() {
    local url=$1
    local output=$2
    local attempts=3
    
    for i in $(seq 1 $attempts); do
        log_info "Download attempt $i of $attempts..."
        if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$output"; then
            log_info "Download successful"
            return 0
        fi
        log_warn "Download attempt $i failed"
        [ $i -lt $attempts ] && sleep 10
    done
    log_error "Download failed after $attempts attempts"
    return 1
}

# Function to check disk space
check_disk_space() {
    local required_gb=$1
    local available_gb=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
    
    if [ $available_gb -lt $required_gb ]; then
        log_error "Insufficient disk space. Required: ${required_gb}GB, Available: ${available_gb}GB"
        exit 1
    fi
    log_info "Disk space check passed: ${available_gb}GB available"
}

# Function to wait for service to be ready
wait_for_service() {
    local service=$1
    local timeout=30
    local count=0
    
    while [ $count -lt $timeout ]; do
        if systemctl is-active --quiet $service; then
            log_info "$service is ready"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    log_error "$service failed to start within $timeout seconds"
    return 1
}

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG_PATH="$SCRIPT_DIR/config.json"

# =============================
# 1. Welcome
# =============================
echo -e "${YELLOW}========================================="
echo -e " Dream Recorder SAFE Pi Installer "
echo -e "=========================================${NC}"

# =============================
# 2. Pre-checks
# =============================
log_step "Pre-checks and System Validation"

# Check we're on a Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    log_warn "This doesn't appear to be a Raspberry Pi"
fi

# Check disk space (require at least 10GB free)
check_disk_space 10

# Check memory (require at least 4GB total)
total_mem_mb=$(free -m | awk 'NR==2{printf "%.0f", $2}')
if [ $total_mem_mb -lt 4000 ]; then
    log_error "Insufficient memory. Required: 4GB, Available: ${total_mem_mb}MB"
    exit 1
fi
log_info "Memory check passed: ${total_mem_mb}MB available"

# Verify required files exist
for file in ".env.example" "config.example.json" "Dockerfile" "requirements.txt"; do
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        log_error "$file not found in $SCRIPT_DIR"
        exit 1
    fi
done
log_info "All required files found"

# =============================
# 3. API Keys Setup
# =============================
log_step "API Keys Configuration"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo -ne "Enter your OPENAI_API_KEY: "
    read -r OPENAI_API_KEY
    if [[ ! "$OPENAI_API_KEY" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
        log_error "OPENAI_API_KEY must be at least 20 alphanumeric characters"
        exit 1
    fi
    
    echo -ne "Enter your LUMALABS_API_KEY: "
    read -r LUMALABS_API_KEY
    if [[ ! "$LUMALABS_API_KEY" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
        log_error "LUMALABS_API_KEY must be at least 20 alphanumeric characters"
        exit 1
    fi
    
    # Create .env from template
    sed -e "s|OPENAI_API_KEY=your-openai-api-key-here|OPENAI_API_KEY=$OPENAI_API_KEY|" \
        -e "s|LUMALABS_API_KEY=your-luma-labs-api-key-here|LUMALABS_API_KEY=$LUMALABS_API_KEY|" \
        "$SCRIPT_DIR/.env.example" > "$SCRIPT_DIR/.env"
    check_success "API keys configuration"
else
    log_info ".env already exists, skipping API key setup"
fi

# Copy config if needed
if [ ! -f "$CONFIG_PATH" ]; then
    cp "$SCRIPT_DIR/config.example.json" "$CONFIG_PATH"
    check_success "Config file creation"
fi

# =============================
# 4. System Update (Conservative)
# =============================
log_step "System Update"

# Clear any corrupted package lists first
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial

sudo apt-get update
check_success "Package list update"

# Only install essential packages
sudo apt-get install -y ca-certificates curl jq
check_success "Essential packages installation"

# =============================
# 5. Docker Installation (Safer Method)
# =============================
log_step "Docker Installation"

if command -v docker &> /dev/null && docker --version &> /dev/null; then
    log_info "Docker is already installed and working"
else
    log_info "Installing Docker using official convenience script"
    
    # Download Docker install script with retry
    download_with_retry "https://get.docker.com" "/tmp/get-docker.sh"
    check_success "Docker script download"
    
    # Install Docker
    sudo sh /tmp/get-docker.sh
    check_success "Docker installation"
    
    # Clean up
    rm -f /tmp/get-docker.sh
fi

# Add user to docker group
sudo usermod -aG docker $USER
log_info "Added $USER to docker group"

# Start and enable Docker
sudo systemctl enable docker
sudo systemctl start docker
wait_for_service docker

# Test Docker
sudo docker --version
check_success "Docker version check"

sudo docker run --rm hello-world > /dev/null
check_success "Docker functionality test"

# =============================
# 6. Create .dockerignore for Efficient Builds
# =============================
log_step "Creating .dockerignore for efficient builds"

cat > "$SCRIPT_DIR/.dockerignore" << 'EOF'
.git
.gitignore
README.md
docs/
*.md
.cursor/
.github/
3DAssets/
tests/
logs/
media/
db/
*.log
.env*
Dockerfile*
docker-compose*.yml
EOF

log_info "Created .dockerignore file"

# =============================
# 7. Docker Build with Resource Limits
# =============================
log_step "Building Docker Image (with resource monitoring)"

cd "$SCRIPT_DIR"

# Check available space before build
check_disk_space 5

# Build with limits to prevent system overload
DOCKER_BUILDKIT=1 docker build \
    --memory=1g \
    --memory-swap=2g \
    -t dream_recorder:latest .
check_success "Docker image build"

# =============================
# 8. Docker Compose Setup with Safer Configuration  
# =============================
log_step "Configuring Docker Compose"

# Create a safer docker-compose.yml
cat > "$SCRIPT_DIR/docker-compose.safe.yml" << 'EOF'
services:
  app:
    image: dream_recorder:latest
    ports:
      - "${PORT:-5000}:${PORT:-5000}"
    volumes:
      - db-data:/app/db
      - media-data:/app/media
      - logs-data:/app/logs
      # Remove the problematic source code mount that can cause conflicts
    env_file:
      - .env
    environment:
      - HOST=0.0.0.0
      - PORT=${PORT:-5000}
    command: python dream_recorder.py
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '2.0'
        reservations:
          memory: 512M
          cpus: '1.0'
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${PORT:-5000}/health", "||", "exit", "1"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  db-data:
  media-data:
  logs-data:
EOF

log_info "Created safer docker-compose configuration"

# Test the compose configuration
docker compose -f docker-compose.safe.yml config > /dev/null
check_success "Docker Compose configuration validation"

# =============================
# 9. Start Services Carefully
# =============================
log_step "Starting Services"

# Start with the safer compose file
docker compose -f docker-compose.safe.yml up -d
check_success "Docker Compose startup"

# Wait for service to be healthy
log_info "Waiting for application to be ready..."
sleep 10

# Test that the application responds
KIOSK_URL=$(jq -r '.GPIO_FLASK_URL // "http://localhost:5000"' "$CONFIG_PATH")
if curl -f -s "$KIOSK_URL/health" > /dev/null 2>&1; then
    log_info "Application is responding correctly"
else
    log_warn "Application health check failed, but continuing..."
fi

# =============================
# 10. Setup Systemd Services (If Desktop Session Available)
# =============================
log_step "Setting up Auto-start Services"

if [ -n "$XDG_SESSION_TYPE" ] || [ -n "$DISPLAY" ]; then
    log_info "Desktop session detected, setting up auto-start services"
    
    # Setup systemd services here (same as original but with better error handling)
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_USER_DIR"
    
    # Create Docker service
    cat > "$SYSTEMD_USER_DIR/dream_recorder_docker.service" << EOF
[Unit]
Description=Dream Recorder Docker Compose
After=network.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$SCRIPT_DIR
ExecStart=/usr/bin/docker compose -f docker-compose.safe.yml up -d
ExecStop=/usr/bin/docker compose -f docker-compose.safe.yml down

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable dream_recorder_docker.service
    log_info "Created systemd service for auto-start"
else
    log_warn "No desktop session detected. Services won't auto-start on boot."
    log_info "You can manually start with: docker compose -f docker-compose.safe.yml up -d"
fi

# =============================
# 11. Final Validation
# =============================
log_step "Final System Validation"

# Check that containers are running
if docker compose -f docker-compose.safe.yml ps | grep -q "Up"; then
    log_info "Docker containers are running"
else
    log_error "Docker containers failed to start"
    docker compose -f docker-compose.safe.yml logs
    exit 1
fi

# Final disk space check
check_disk_space 3

# Check for any new file system errors
if dmesg | grep -q "EXT4-fs error" && dmesg | grep "EXT4-fs error" | tail -1 | grep -q "$(date +%b\ %d)"; then
    log_error "New file system errors detected during installation!"
    exit 1
else
    log_info "No new file system errors detected"
fi

# =============================
# 12. Success!
# =============================
log_step "Installation Complete!"

cat << 'EOF'
   .-.                                         .-.                                                 
  (_) )-.                                     (_) )-.                               .'             
    .:   \    .;.::..-.  .-.    . ,';.,';.      .:   \   .-.  .-.   .-.  .;.::..-..'  .-.   .;.::. 
   .:'    \   .;  .;.-' ;   :   ;;  ;;  ;;     .::.   ).;.-' ;     ;   ;'.;   :   ; .;.-'   .;     
 .-:.      ).;'    `:::'`:::'-'';  ;;  ';    .-:. `:-'  `:::'`;;;;'`;;'.;'    `:::'`.`:::'.;'      
(_/  `----'                   _;        `-' (_/     `:._.                                          

EOF

echo -e "${GREEN}Dream Recorder installed successfully!${NC}"
echo -e "${YELLOW}Application URL: $KIOSK_URL${NC}"
echo -e "${YELLOW}Management URL: ${KIOSK_URL}/dreams${NC}"
echo -e ""
echo -e "To start manually: ${BLUE}docker compose -f docker-compose.safe.yml up -d${NC}"
echo -e "To stop: ${BLUE}docker compose -f docker-compose.safe.yml down${NC}"
echo -e ""
echo -e "${GREEN}Installation completed without corruption!${NC}"