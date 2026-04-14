#!/bin/bash

# Dynamically resolve the absolute path to the wp-paas root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PAAS_ROOT="$(dirname "$SCRIPT_DIR")"

# You can now delete any hardcoded references to /opt/wp-paas
# and replace them with "$PAAS_ROOT". For example:
TENANTS_DIR="$PAAS_ROOT/tenants"

# ==========================================
# 1. Parameter Parsing & Comprehensive Help
# ==========================================
COMMAND=""
TARGET_DOMAIN=""
AUTO_CONFIRM=false
AUTO_START=""

usage() {
    echo -e "======================================================================="
    echo -e "                 Zero-Touch Deployment CLI for WordPress               "
    echo -e "======================================================================="
    echo -e "SYNOPSIS:"
    echo -e "  $0 [command] [options]"
    echo -e ""
    echo -e "COMMANDS:"
    echo -e "  new <domain>  Scaffold a new site (e.g., new abc.com or new xyz.abc.com)"
    echo -e "  init          Setup disks, mount them to the OS, and prepare Docker."
    echo -e "  update        Safely unmount, resize disks, and remount them."
    echo -e "  down          Safely stops Docker and unmounts disks from the OS."
    echo -e ""
    echo -e "OPTIONS:"
    echo -e "  -y, --yes     Non-interactive mode. Skips all confirmation prompts."
    echo -e "  --start       Automatically start containers after init/update."
    echo -e "  -h, --help    Display this help manual."
    echo -e "======================================================================="
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        new) 
            COMMAND="new"
            # Check if a second argument exists and doesn't start with a hyphen
            if [[ "$#" -ge 2 && "$2" != -* ]]; then
                TARGET_DOMAIN="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        init|update|down) COMMAND="$1"; shift ;;
        -y|--yes) AUTO_CONFIRM=true; shift ;;
        --start) AUTO_START="yes"; shift ;;
        -h|--help) usage ;;
        *) echo "Error: Unknown parameter passed: $1"; echo ""; usage ;;
    esac
done

if [[ -z "$COMMAND" ]]; then usage; fi

# ==========================================
# 2. SCAFFOLDING LOGIC (The 'new' command)
# ==========================================
if [ "$COMMAND" == "new" ]; then
    if [ -z "$TARGET_DOMAIN" ]; then
        echo "🛑 Error: The 'new' command requires a domain parameter."
        echo "Example: $0 new abc.com or $0 new xyz.abc.com"
        exit 1
    fi

    # Regex check for a valid domain format (requires at least one dot and valid characters)
    if [[ ! "$TARGET_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "🛑 ERROR: '$TARGET_DOMAIN' is not a valid domain format."
        echo "Please provide a valid domain (e.g., test2.induslevel.com or abc.com)."
        exit 1
    fi

    echo "=================================================================="
    echo " 🏗️ SCAFFOLDING NEW ENVIRONMENT: $TARGET_DOMAIN "
    echo "=================================================================="

    # Generate the Slug: Remove dots/hyphens and uppercase
    SLUG=$(echo "$TARGET_DOMAIN" | tr -d '.-' | tr '[:lower:]' '[:upper:]')
    
    # Character Limit Check
    # MariaDB max database name is 64 chars. ${SLUG}_db requires 3 chars. 
    if [ ${#SLUG} -gt 55 ]; then
        echo "🛑 ERROR: The generated slug ($SLUG) is too long (${#SLUG} characters)."
        echo "MariaDB has a strict 64-character limit for database names."
        echo "Please use a shorter domain name."
        exit 1
    elif [ ${#SLUG} -gt 45 ]; then
        echo "⚠️ WARNING: The generated slug ($SLUG) is ${#SLUG} characters long."
        echo "Approaching database naming limits."
    fi

    # Check 1: Do files already exist?
    if [ -f .env ] || [ -f compose.yaml ]; then
        echo "🛑 ERROR: Found an existing .env or compose.yaml in this directory."
        echo "Please move or delete them before scaffolding a new site."
        exit 1
    fi

    # Check 2: Do Docker containers with this slug already exist?
    EXISTING_DOCKER=$(docker ps -a --format '{{.Names}}' | grep "^${SLUG}-")
    if [ -n "$EXISTING_DOCKER" ]; then
        echo "🛑 ERROR: Docker containers for slug '${SLUG}' already exist:"
        echo "$EXISTING_DOCKER"
        echo "Please stop and remove them before proceeding."
        exit 1
    fi

    echo "✅ No conflicts detected. Generating credentials..."
    
    # Generate Highly Secure Random Credentials
    RANDOM_ROOT_DB=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    RANDOM_USER_DB=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    RANDOM_WP_PASS=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)

    echo "📄 Writing .env file..."
    cat <<EOF > .env
# Core Routing
FULL_DOMAIN=$TARGET_DOMAIN
DOMAIN_SLUG=$SLUG

# Database Passwords 
MYSQL_ROOT_PASSWORD=$RANDOM_ROOT_DB
MYSQL_PASSWORD=$RANDOM_USER_DB

# Webadmin Credential
WP_ADMIN_USER=admin
WP_ADMIN_PASSWORD=$RANDOM_WP_PASS
WP_ADMIN_EMAIL=admin@$TARGET_DOMAIN

# Software Versions
WORDPRESS_VERSION=6.9.4-php8.3-apache
MARIADB_VERSION=11.4
WP_CLI_VERSION=cli-php8.3
REDIS_VERSION=7-alpine

# Resource Limits
WP_CPU_LIMIT=0.5
WP_MEM_LIMIT=512M
DB_CPU_LIMIT=0.5
DB_MEM_LIMIT=512M
REDIS_CPU_LIMIT=0.25
REDIS_MEM_LIMIT=128M

# Hard Drive Quotas
WP_DISK_QUOTA=2G
DB_DISK_QUOTA=2G
EOF
    
    chmod 600 .env

    echo "🐳 Writing compose.yaml..."
    cat <<'EOF' > compose.yaml
services:
  db:
    image: mariadb:${MARIADB_VERSION:-11.4}
    container_name: ${DOMAIN_SLUG}-db
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: '${DB_CPU_LIMIT:-0.5}'
          memory: '${DB_MEM_LIMIT:-512M}'
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${DOMAIN_SLUG}_db
      MYSQL_USER: ${DOMAIN_SLUG}_user
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./db_data_mount:/var/lib/mysql
    networks:
      - backend
    # Native MariaDB healthcheck to ensure it's fully ready before other containers start
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 2m
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:${REDIS_VERSION:-7-alpine}
    container_name: ${DOMAIN_SLUG}-redis
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: '${REDIS_CPU_LIMIT:-0.25}'
          memory: '${REDIS_MEM_LIMIT:-128M}'
    networks:
      - backend

  wordpress:
    image: wordpress:${WORDPRESS_VERSION:-6.9.4-php8.3-apache}
    container_name: ${DOMAIN_SLUG}-wordpress
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    depends_on:
      db:
        condition: service_healthy # Wait for DB healthcheck to pass
      redis:
        condition: service_started
    deploy:
      resources:
        limits:
          cpus: '${WP_CPU_LIMIT:-0.5}'
          memory: '${WP_MEM_LIMIT:-512M}'
    environment:
      WORDPRESS_DB_HOST: ${DOMAIN_SLUG}-db:3306
      WORDPRESS_DB_USER: ${DOMAIN_SLUG}_user
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: ${DOMAIN_SLUG}_db
      WORDPRESS_CONFIG_EXTRA: |
        $$_SERVER['HTTPS']='on';
        define('WP_REDIS_HOST', '${DOMAIN_SLUG}-redis');
        define('WP_REDIS_PORT', 6379);
        if (isset($$_SERVER['HTTP_CF_CONNECTING_IP'])) {
            $$_SERVER['REMOTE_ADDR'] = $$_SERVER['HTTP_CF_CONNECTING_IP'];
        } elseif (isset($$_SERVER['HTTP_X_FORWARDED_FOR'])) {
            $$_SERVER['REMOTE_ADDR'] = trim(explode(',', $$_SERVER['HTTP_X_FORWARDED_FOR'])[0]);
        }
    volumes:
      - ./wp_data_mount:/var/www/html
    networks:
      - frontend
      - backend
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${DOMAIN_SLUG}.rule=Host(`${FULL_DOMAIN}`)"
      - "traefik.http.services.${DOMAIN_SLUG}.loadbalancer.server.port=80"
      - "traefik.docker.network=frontend"
      - "traefik.http.middlewares.${DOMAIN_SLUG}-compress.compress=true"
      - "traefik.http.routers.${DOMAIN_SLUG}.middlewares=${DOMAIN_SLUG}-compress"

  wp-setup:
    image: wordpress:${WP_CLI_VERSION:-cli-php8.3}
    container_name: ${DOMAIN_SLUG}-setup
    user: "33:33" 
    depends_on:
      db:
        condition: service_healthy # Wait for DB healthcheck to pass
      redis:
        condition: service_started
      wordpress:
        condition: service_started
    volumes:
      - ./wp_data_mount:/var/www/html
    networks:
      - backend
    environment:
      WORDPRESS_DB_HOST: ${DOMAIN_SLUG}-db:3306
      WORDPRESS_DB_USER: ${DOMAIN_SLUG}_user
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: ${DOMAIN_SLUG}_db
      WP_CLI_CACHE_DIR: "/tmp/wp-cli-cache"
      WORDPRESS_CONFIG_EXTRA: |
        $$_SERVER['HTTPS']='on';
        define('WP_REDIS_HOST', '${DOMAIN_SLUG}-redis');
        define('WP_REDIS_PORT', 6379);
        if (isset($$_SERVER['HTTP_CF_CONNECTING_IP'])) {
            $$_SERVER['REMOTE_ADDR'] = $$_SERVER['HTTP_CF_CONNECTING_IP'];
        } elseif (isset($$_SERVER['HTTP_X_FORWARDED_FOR'])) {
            $$_SERVER['REMOTE_ADDR'] = trim(explode(',', $$_SERVER['HTTP_X_FORWARDED_FOR'])[0]);
        }
    entrypoint: [ "/bin/sh", "-c" ]
    command:
      - |
        echo "Database reported healthy. Booting setup script..."
        sleep 5 # Small buffer just in case
        
        if wp core is-installed; then
          echo "WordPress is already installed. Skipping setup."
        else
          echo "Installing WordPress..."
          
          ADMIN_PASS="${WP_ADMIN_PASSWORD}"
          if [ -z "$$ADMIN_PASS" ]; then
            ADMIN_PASS=$$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
            echo "=================================================================="
            echo " ⚠️ NO PASSWORD PROVIDED IN .ENV! "
            echo " 🔐 AUTO-GENERATED ADMIN PASSWORD: $$ADMIN_PASS "
            echo " 👉 SAVE THIS! It will only be shown once in these logs."
            echo "=================================================================="
          fi

          wp core install \
            --url="https://${FULL_DOMAIN}" \
            --title="${FULL_DOMAIN} Site" \
            --admin_user="${WP_ADMIN_USER:-admin}" \
            --admin_password="$$ADMIN_PASS" \
            --admin_email="${WP_ADMIN_EMAIL:-admin@${FULL_DOMAIN}}" \
            --skip-email
            
          echo "=================================================================="
          echo " 🛡️ RUNNING SECURITY HARDENING & CACHE SETUP... "
          echo "=================================================================="
          
          wp plugin delete hello akismet
          wp theme delete twentytwentythree twentytwentyfour

          echo "Pre-creating cache directory to suppress Apache autoindex warnings..."
          mkdir -p /var/www/html/wp-content/cache && echo '<?php // Silence is golden.' > /var/www/html/wp-content/cache/index.php
          
          echo "Installing Wordfence, Limit Login Attempts, WP Super Cache, and Redis..."
          wp plugin install limit-login-attempts-reloaded wordfence wp-super-cache redis-cache --activate
          
          echo "Enabling Redis Object Cache..."
          wp redis enable

          echo "Enabling WP Super Cache (Page Caching)..."
          wp config set WP_CACHE true --raw
          wp eval "if (function_exists('wp_cache_enable')) { wp_cache_enable(); }"
          
          echo "=================================================================="
          echo " 🔄 ENABLING AUTO-UPDATES... "
          echo "=================================================================="
          
          wp plugin auto-updates enable --all
          wp theme auto-updates enable --all
          
          echo "=================================================================="
          echo " ✅ INSTALLATION, HARDENING & CACHING COMPLETE! "
          echo "=================================================================="
        fi

networks:
  frontend:
    external: true
  backend:
    external: true
EOF

    echo "✅ Setup files successfully scaffolded!"
    echo "You can now run: $0 init -y --start"
    exit 0
fi

# ==========================================
# 3. Pre-Flight Security Check & .env Load
# ==========================================
if [ -f .env ]; then
    ENV_PERMS=$(stat -c "%a" .env)
    if [ "$ENV_PERMS" != "600" ]; then
        echo -e "\n=================================================================="
        echo -e " 🛑 CRITICAL SECURITY ERROR: VULNERABLE .ENV FILE"
        echo -e "=================================================================="
        echo -e " Your .env file permissions are currently set to $ENV_PERMS."
        echo -e " Please secure the file by running:  chmod 600 .env"
        echo -e "==================================================================\n"
        exit 1
    fi
    export $(grep -v '^#' .env | xargs)
else
    echo "Error: .env not found."
    exit 1
fi

# ==========================================
# 4. Variable Validation & Default Injection
# ==========================================
USING_DEFAULTS=false
DEFAULT_WARNING=""

check_and_default() {
    local var_name=$1; local default_val=$2; local current_val="${!var_name}"
    if [ -z "$current_val" ]; then
        export "$var_name=$default_val"
        DEFAULT_WARNING="${DEFAULT_WARNING}\n  - $var_name (Defaulting to: $default_val)"
        USING_DEFAULTS=true
    fi
}

check_and_default "WP_DISK_QUOTA" "2G"
check_and_default "DB_DISK_QUOTA" "2G"
check_and_default "WP_CPU_LIMIT" "0.5"
check_and_default "WP_MEM_LIMIT" "512M"
check_and_default "DB_CPU_LIMIT" "0.5"
check_and_default "DB_MEM_LIMIT" "512M"
check_and_default "REDIS_CPU_LIMIT" "0.25"
check_and_default "REDIS_MEM_LIMIT" "128M"

if [ "$USING_DEFAULTS" = true ] && [ "$COMMAND" != "down" ]; then
    echo -e "====================================================="
    echo -e " WARNING: MISSING CONFIGURATION DETECTED"
    echo -e "====================================================="
    echo -e "Temporarily injecting safe defaults:$DEFAULT_WARNING"
    echo -e "====================================================="
    if [ "$AUTO_CONFIRM" = false ]; then
        read -p "Proceed with defaults? [y/N]: " default_confirm
        if [[ "$default_confirm" != [yY]* ]]; then exit 0; fi
    fi
fi

# ==========================================
# 5. Auto-Generate Secure Credentials
# ==========================================
if [ "$COMMAND" != "down" ]; then
    # Inject requested global defaults
    if [ -z "$WP_ADMIN_USER" ]; then export WP_ADMIN_USER="admin"; fi
    if [ -z "$WP_ADMIN_EMAIL" ]; then export WP_ADMIN_EMAIL="admin@${FULL_DOMAIN}"; fi

    if [ -z "$WP_ADMIN_PASSWORD" ]; then
        RANDOM_PASS=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
        export WP_ADMIN_PASSWORD="$RANDOM_PASS"
        
        echo "" >> .env
        echo "# Auto-Generated Secure Credentials" >> .env
        echo "WP_ADMIN_USER=$WP_ADMIN_USER" >> .env
        echo "WP_ADMIN_PASSWORD=$RANDOM_PASS" >> .env
        echo "WP_ADMIN_EMAIL=$WP_ADMIN_EMAIL" >> .env
        
        echo -e "====================================================="
        echo -e " 🔐 SECURITY NOTICE: RANDOM PASSWORD GENERATED"
        echo -e "====================================================="
        echo -e " Username: $WP_ADMIN_USER"
        echo -e " Password: $RANDOM_PASS"
        echo -e "====================================================="
        sleep 2
    fi
fi

# ==========================================
# 6. Teardown Logic (The 'down' command)
# ==========================================
if [ "$COMMAND" == "down" ]; then
    echo "Taking environment offline..."
    docker compose down
    echo "Unmounting virtual disks from host OS..."
    if mountpoint -q wp_data_mount; then umount wp_data_mount; fi
    if mountpoint -q db_data_mount; then umount db_data_mount; fi
    echo "Environment is fully offline and disks are safely unmounted."
    exit 0
fi

# ==========================================
# 7. Safety Check & Prompts
# ==========================================
RUNNING_CONTAINERS=$(docker compose ps -q 2>/dev/null)
if [ -n "$RUNNING_CONTAINERS" ]; then
    echo "ERROR: CONTAINERS ARE CURRENTLY RUNNING!"
    echo "Run '$0 down' first to protect your data."
    exit 1
fi

if [ "$AUTO_CONFIRM" = false ]; then
    echo "Target: ${FULL_DOMAIN} | Action: $COMMAND"
    read -p "Proceed with disk operations? [y/N]: " confirm
    if [[ "$confirm" != [yY]* ]]; then exit 0; fi
fi

# ==========================================
# 8. Disk Operations (Init & Update)
# ==========================================
if [ "$COMMAND" == "init" ]; then
    echo "Initializing virtual disks..."
    if [ ! -f "wp_data.img" ]; then
        fallocate -l $WP_DISK_QUOTA wp_data.img; mkfs.ext4 -F wp_data.img > /dev/null 2>&1
    fi
    if [ ! -f "db_data.img" ]; then
        fallocate -l $DB_DISK_QUOTA db_data.img; mkfs.ext4 -F db_data.img > /dev/null 2>&1
    fi

elif [ "$COMMAND" == "update" ]; then
    echo "Safely resizing virtual disks..."
    if mountpoint -q wp_data_mount; then umount wp_data_mount; fi
    if mountpoint -q db_data_mount; then umount db_data_mount; fi

    if [ -f "wp_data.img" ]; then
        truncate -s $WP_DISK_QUOTA wp_data.img
        e2fsck -fp wp_data.img > /dev/null 2>&1; resize2fs wp_data.img > /dev/null 2>&1
    fi
    if [ -f "db_data.img" ]; then
        truncate -s $DB_DISK_QUOTA db_data.img
        e2fsck -fp db_data.img > /dev/null 2>&1; resize2fs db_data.img > /dev/null 2>&1
    fi
fi

# ==========================================
# 9. Host-OS Mounts
# ==========================================
echo "Mounting virtual disks to host OS..."
mkdir -p wp_data_mount db_data_mount

if ! mountpoint -q wp_data_mount; then mount -o loop wp_data.img wp_data_mount; fi
if ! mountpoint -q db_data_mount; then mount -o loop db_data.img db_data_mount; fi

# ==========================================
# 10. Post-Execution Start Sequence
# ==========================================
echo "Filesystem operations completed successfully."
if [ "$AUTO_START" == "yes" ]; then
    echo "Starting Docker Compose..."
    if docker compose up -d; then
        echo "Success! The ${FULL_DOMAIN} environment is live."
    else
        echo "Error: Docker Compose failed to start."
        exit 1
    fi
fi
