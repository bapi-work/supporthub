#!/bin/bash

# Deployment script for SupportHub

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== SupportHub Deployment ===${NC}\n"

# Check if .env file exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found!${NC}"
    echo -e "Please create a .env file based on .env.example"
    exit 1
fi

# Load DOMAIN and EMAIL from .env (robustly)
DOMAIN=$(grep -E "^DOMAIN=" .env | cut -d '=' -f2 | tr -d '\r' | tr -d '"' | tr -d "'")
EMAIL=$(grep -E "^EMAIL=" .env | cut -d '=' -f2 | tr -d '\r' | tr -d '"' | tr -d "'")

# Check DOMAIN variable
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Error: DOMAIN is not set in .env${NC}"
    exit 1
elif [ "$DOMAIN" == "localhost" ]; then
    echo -e "${YELLOW}Warning: DOMAIN is set to 'localhost'.${NC}"
    echo -e "${YELLOW}SSL certificate will be self-signed (testing mode).${NC}"
    echo -e "${YELLOW}For production SSL, set DOMAIN to your actual domain name.${NC}\n"
    read -p "Continue with localhost deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check EMAIL variable (needed for Let's Encrypt)
if [ -z "$EMAIL" ] || [ "$EMAIL" == "admin@localhost" ]; then
    echo -e "${YELLOW}Warning: EMAIL is not set or is default 'admin@localhost'.${NC}"
    echo -e "${YELLOW}Let's Encrypt requires a valid email for expiration notices.${NC}"
    if [ "$DOMAIN" != "localhost" ]; then
        echo -e "${RED}Error: You must set a valid EMAIL in .env for production SSL.${NC}"
        exit 1
    fi
fi


echo -e "${GREEN}Deploying with Docker Compose...${NC}"

# Rebuild app and nginx, and force verify SSL
if ! docker compose -f compose.production.yml up -d --build; then
    echo -e "${RED}❌ Deployment failed: Docker Compose could not start all services.${NC}"
    echo -e "Check: docker compose -f compose.production.yml ps -a, docker logs supporthub_ssl_init"
    exit 1
fi

# Run database migrations (creates/updates schema on first run and after updates)
echo -e "${GREEN}Running database migrations...${NC}"
docker compose -f compose.production.yml exec -T app npm run db:push && \
    echo -e "${GREEN}✅ Database migrations applied.${NC}" || \
    echo -e "${YELLOW}⚠️  Migration step skipped or failed — app may need db:push if this is a first run.${NC}"

echo -e "${GREEN}Deployment started. Waiting for SSL initialization...${NC}"

# Monitor ssl_init container
docker logs -f supporthub_ssl_init &
LOG_PID=$!

# Wait for container to exit
EXIT_CODE=$(docker wait supporthub_ssl_init)
kill $LOG_PID 2>/dev/null

if [ "$EXIT_CODE" != "0" ]; then
    echo -e "\n${RED}SSL Initialization failed (Exit code: $EXIT_CODE).${NC}"
    echo -e "Check logs with: docker logs supporthub_ssl_init"
    exit 1
fi

echo -e "\n${GREEN}SSL Initialization finished.${NC}"
echo -e "${GREEN}Restarting Nginx to apply certificates...${NC}"
# restart (not reload) so it also recovers if nginx is not currently running
if ! docker compose -f compose.production.yml restart nginx; then
    echo -e "${RED}❌ Deployment failed: could not restart Nginx.${NC}"
    exit 1
fi

# Verify Nginx is really serving. Require several successes in a row so that a
# container stuck in a restart loop is not mistaken for a running one.
echo -e "${GREEN}Verifying Nginx...${NC}"
OK_COUNT=0
for _ in $(seq 1 30); do
    sleep 2
    if docker compose -f compose.production.yml exec -T nginx \
        wget -q --spider http://127.0.0.1/nginx-health >/dev/null 2>&1; then
        OK_COUNT=$((OK_COUNT + 1))
        [ "$OK_COUNT" -ge 3 ] && break
    else
        OK_COUNT=0
    fi
done

if [ "$OK_COUNT" -lt 3 ]; then
    echo -e "${RED}❌ Deployment failed: Nginx is not running. Last log lines:${NC}"
    docker logs --tail 20 supporthub_nginx
    exit 1
fi
echo -e "${GREEN}✅ Nginx is running.${NC}"

# Verify the certificate. init-ssl.sh exits 0 even when it falls back to a
# self-signed certificate, so its exit code alone proves nothing.
CERT_INFO=$(docker compose -f compose.production.yml exec -T nginx \
    openssl x509 -in /etc/nginx/ssl/cert.pem -noout -issuer -subject -enddate 2>/dev/null | tr -d '\r')
CERT_ISSUER=$(echo "$CERT_INFO" | sed -n 's/^issuer= *//p')
CERT_SUBJECT=$(echo "$CERT_INFO" | sed -n 's/^subject= *//p')
CERT_EXPIRY=$(echo "$CERT_INFO" | sed -n 's/^notAfter=//p')

if [ -z "$CERT_ISSUER" ]; then
    echo -e "${RED}❌ Deployment failed: could not read the SSL certificate.${NC}"
    exit 1
fi

if ! docker compose -f compose.production.yml exec -T nginx \
    openssl x509 -in /etc/nginx/ssl/cert.pem -noout -checkend 0 >/dev/null 2>&1; then
    echo -e "${RED}❌ Deployment failed: the SSL certificate expired on $CERT_EXPIRY.${NC}"
    exit 1
fi

if [ "$CERT_ISSUER" == "$CERT_SUBJECT" ]; then
    # Self-signed is expected only when testing on localhost or an IP address
    if [ "$DOMAIN" == "localhost" ] || [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}⚠️  Using a self-signed certificate (testing mode).${NC}"
    else
        echo -e "${RED}❌ Deployment incomplete: the site is up, but with a self-signed certificate.${NC}"
        echo -e "Let's Encrypt did not issue one. Check logs with: docker logs supporthub_ssl_init"
        exit 1
    fi
fi

echo -e "${GREEN}Certificate valid until: $CERT_EXPIRY${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${GREEN}Your site should be live at https://$DOMAIN${NC}"
