#!/usr/bin/env bash
set -e

# 1) Cria e corrige permissões
mkdir -p /var/www/html/config /var/www/html/var /var/www/html/media /var/www/html/translations
chown -R www-data:www-data \
  /var/www/html/config \
  /var/www/html/var \
  /var/www/html/media \
  /var/www/html/translations

# 2) Espera pelo MySQL
until mysqladmin ping \
     -h "$MAUTIC_DB_HOST" \
     -u "$MAUTIC_DB_USER" \
     -p"$MAUTIC_DB_PASSWORD" \
     --silent; do
  echo "⏳ Aguardando MySQL em $MAUTIC_DB_HOST..."
  sleep 5
done

# 3) (Opcional) Espera pelo Redis
until redis-cli -h "$REDIS_HOST" ping >/dev/null 2>&1; do
  echo "⏳ Aguardando Redis em $REDIS_HOST..."
  sleep 5
done

# 4) Chama o entrypoint original e inicia o Apache
exec docker-php-entrypoint apache2-foreground
