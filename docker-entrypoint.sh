#!/usr/bin/env bash
set -e

echo "🚀 Iniciando Mautic..."

# 1) Criar diretórios
mkdir -p /var/www/html/{config,var/{cache,logs,tmp},media,translations,docroot/plugins}

# 2) Corrigir permissões
chown -R www-data:www-data /var/www/html 2>/dev/null || true
chmod -R 755 /var/www/html 2>/dev/null || true
chmod -R 775 /var/www/html/{var,config,media} 2>/dev/null || true

# 3) Aguardar MySQL (max 30s)
echo "⏳ Esperando MySQL..."
for i in {1..15}; do
  if mysqladmin ping -h "$MAUTIC_DB_HOST" -u "$MAUTIC_DB_USER" -p"$MAUTIC_DB_PASSWORD" --silent 2>/dev/null; then
    echo "✅ MySQL OK"
    break
  fi
  echo "   Tentativa $i..."
  sleep 2
done

# 4) Aguardar Redis (max 10s)
echo "⏳ Esperando Redis..."
for i in {1..5}; do
  if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
    echo "✅ Redis OK"
    break
  fi
  sleep 2
done

# 5) Instalar plugin rapidamente (em background se demorar)
echo "📥 Instalando plugin SES..."
if [ ! -d "/var/www/html/docroot/plugins/AmazonSesBundle" ]; then
  cd /var/www/html/docroot/plugins
  
  # Tentar com git primeiro
  if command -v git &> /dev/null; then
    timeout 30 git clone --depth 1 https://github.com/pm-pmaas/etailors_amazon_ses.git AmazonSesBundle 2>&1 || echo "⚠️  Git falhou"
  fi
  
  # Se git falhou, tentar wget
  if [ ! -d "AmazonSesBundle" ]; then
    timeout 30 wget -q https://github.com/pm-pmaas/etailors_amazon_ses/archive/master.zip -O amazon-ses.zip 2>/dev/null && \
    unzip -q amazon-ses.zip && \
    mv etailors_amazon_ses-master AmazonSesBundle 2>/dev/null && \
    rm amazon-ses.zip || echo "⚠️  Download falhou"
  fi
  
  chown -R www-data:www-data AmazonSesBundle 2>/dev/null || true
fi

# 6) Instalar composer deps rapidamente
echo "🔧 Instalando dependências..."
cd /var/www/html
if command -v composer &> /dev/null; then
  timeout 120 composer require aws/aws-sdk-php --no-interaction --no-dev --no-scripts 2>&1 | tail -3 || echo "⚠️  Composer timeout"
fi

# 7) Limpar cache
echo "🧹 Limpando cache..."
rm -rf /var/www/html/var/cache/{prod,dev} 2>/dev/null || true

# 8) Recarregar plugins (rápido)
echo "🔌 Recarregando plugins..."
php bin/console mautic:plugins:reload --env=prod 2>&1 | tail -3 || true

# 9) Warm cache
php bin/console cache:warmup --env=prod 2>&1 | tail -3 || true

echo "✅ Setup concluído! Iniciando Apache..."
echo "================================================"

# Iniciar Apache
exec docker-php-entrypoint apache2-foreground
