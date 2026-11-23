#!/bin/sh

# Nginx entrypoint with SSL certificate initialization
# Creates temporary self-signed certificates if they don't exist

set -e

echo "🔧 Nginx SSL Pre-Start Check..."

# Install openssl if not present (for alpine)
if ! command -v openssl >/dev/null 2>&1; then
    echo "📦 Installing openssl..."
    apk add --no-cache openssl
fi

# Create SSL directory if it doesn't exist
mkdir -p /etc/nginx/ssl

# Check if certificates already exist
if [ ! -f "/etc/nginx/ssl/cert.pem" ] || [ ! -f "/etc/nginx/ssl/key.pem" ]; then
    echo "📝 Creating temporary self-signed certificates for Nginx startup..."
    
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout /etc/nginx/ssl/key.pem \
        -out /etc/nginx/ssl/cert.pem \
        -subj "/CN=localhost" 2>/dev/null
    
    echo "✅ Temporary certificates created"
else
    echo "✅ Certificates already exist"
fi

echo "🔄 Applying environment variables to Nginx config..."
# We need to install gettext for envsubst if it's not there, but nginx:alpine usually has it or we can sed.
# simpler to use sed given restricted environment? No, envsubst is cleaner.
# Check if envsubst is available
if ! command -v envsubst >/dev/null 2>&1; then
    apk add --no-cache gettext
fi

# Replace vars in conf.d
# First clean up default configs to avoid conflicts
rm -rf /etc/nginx/conf.d/*

# Copy templates to conf.d (writable location)
# We assume templates are mounted at /etc/nginx/templates/conf.d
if [ -d "/etc/nginx/templates/conf.d" ]; then
    cp /etc/nginx/templates/conf.d/*.conf /etc/nginx/conf.d/
else
    # Fallback if mounted directly (though this causes RO issues, addressed via compose change)
    echo "Warning: Templates not found at expected location"
fi

export DOMAIN=$(echo "$DOMAIN" | tr -d '\r')

if [ -z "$DOMAIN" ]; then
    echo "❌ DOMAIN environment variable is empty - set it under the nginx service 'environment:' in compose" >&2
    exit 1
fi

for file in /etc/nginx/conf.d/*.conf; do
    if [ -f "$file" ]; then
        echo "Processing $file..."
        envsubst '${DOMAIN}' < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi
done

# Keep nginx's copy of the certificate in step with Let's Encrypt.
# The certbot container renews into /etc/letsencrypt, but nginx serves the copy
# in /etc/nginx/ssl, so a renewal only takes effect once it is copied over and
# nginx is reloaded.
LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"
SSL_DIR="/etc/nginx/ssl"
CERT_SYNC_INTERVAL="${CERT_SYNC_INTERVAL:-3600}"

# Succeeds only if a new certificate was installed
sync_certs() {
    [ -f "$LIVE_DIR/fullchain.pem" ] && [ -f "$LIVE_DIR/privkey.pem" ] || return 1

    if cmp -s "$LIVE_DIR/fullchain.pem" "$SSL_DIR/cert.pem" &&
       cmp -s "$LIVE_DIR/privkey.pem" "$SSL_DIR/key.pem"; then
        return 1
    fi

    cp "$LIVE_DIR/fullchain.pem" "$SSL_DIR/cert.pem.new" || return 1
    (umask 077 && cp "$LIVE_DIR/privkey.pem" "$SSL_DIR/key.pem.new") || return 1

    # Never install an expired certificate, or a key that does not match it
    # (for example if certbot is part-way through writing the new pair)
    cert_pub=$(openssl x509 -in "$SSL_DIR/cert.pem.new" -noout -pubkey 2>/dev/null) || cert_pub=""
    key_pub=$(openssl pkey -in "$SSL_DIR/key.pem.new" -pubout 2>/dev/null) || key_pub=""
    if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ] ||
       ! openssl x509 -in "$SSL_DIR/cert.pem.new" -noout -checkend 0 >/dev/null 2>&1; then
        echo "⚠️  Ignoring unusable Let's Encrypt certificate in $LIVE_DIR" >&2
        rm -f "$SSL_DIR/cert.pem.new" "$SSL_DIR/key.pem.new"
        return 1
    fi

    mv "$SSL_DIR/key.pem.new" "$SSL_DIR/key.pem" &&
        mv "$SSL_DIR/cert.pem.new" "$SSL_DIR/cert.pem"
}

watch_certs() {
    reload_pending=0
    while :; do
        sleep "$CERT_SYNC_INTERVAL"
        if sync_certs; then
            echo "🔐 New Let's Encrypt certificate installed"
            reload_pending=1
        fi
        if [ "$reload_pending" = 1 ]; then
            if nginx -t -q && nginx -s reload; then
                echo "✅ Nginx reloaded with the new certificate"
                reload_pending=0
            else
                echo "❌ Nginx reload failed, will retry" >&2
            fi
        fi
    done
}

if sync_certs; then
    echo "🔐 Let's Encrypt certificate installed"
fi
watch_certs &

echo "🚀 Starting Nginx..."

# Start Nginx with the original entrypoint
exec /docker-entrypoint.sh nginx -g 'daemon off;'
