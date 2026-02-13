#!/usr/bin/env bash
set -e

echo "🚀 Iniciando Mautic com setup automático..."
echo "================================================"

# 1) Criar diretórios necessários
echo "[1/15] 📁 Criando diretórios..."
mkdir -p /var/www/html/config
mkdir -p /var/www/html/var/cache
mkdir -p /var/www/html/var/logs
mkdir -p /var/www/html/var/tmp
mkdir -p /var/www/html/media
mkdir -p /var/www/html/translations
mkdir -p /var/www/html/docroot/plugins
echo "✅ Diretórios criados"

# 2) Corrigir permissões
echo "[2/15] 🔐 Corrigindo permissões..."
chown -R www-data:www-data \
  /var/www/html/config \
  /var/www/html/var \
  /var/www/html/media \
  /var/www/html/translations \
  /var/www/html/docroot \
  /var/www/html 2>/dev/null || true

chmod -R 755 /var/www/html 2>/dev/null || true
chmod -R 775 /var/www/html/var 2>/dev/null || true
chmod -R 775 /var/www/html/config 2>/dev/null || true
chmod -R 775 /var/www/html/media 2>/dev/null || true
echo "✅ Permissões corrigidas"

# 3) Aguardar MySQL
echo "[3/15] ⏳ Aguardando MySQL em $MAUTIC_DB_HOST:$MAUTIC_DB_PORT..."
max_attempts=30
attempt=0
until mysqladmin ping \
     -h "$MAUTIC_DB_HOST" \
     -u "$MAUTIC_DB_USER" \
     -p"$MAUTIC_DB_PASSWORD" \
     --silent 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "❌ MySQL não respondeu após $max_attempts tentativas!"
    exit 1
  fi
  echo "   ⏳ Tentativa $attempt/$max_attempts..."
  sleep 2
done
echo "✅ MySQL está pronto!"

# 4) Aguardar Redis (usa REDIS_HOST ou MAUTIC_REDIS_HOST como fallback)
REDIS_HOST=${REDIS_HOST:-$MAUTIC_REDIS_HOST}
REDIS_PORT=${REDIS_PORT:-$MAUTIC_REDIS_PORT}
echo "[4/15] ⏳ Aguardando Redis em $REDIS_HOST:$REDIS_PORT..."
attempt=0
until redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "⚠️  Redis não respondeu, continuando mesmo assim..."
    break
  fi
  echo "   ⏳ Tentativa $attempt/$max_attempts..."
  sleep 2
done
echo "✅ Redis está pronto!"

# 5) Verificar se Composer está disponível
echo "[5/15] 🔧 Verificando Composer..."
if ! command -v composer &> /dev/null; then
  echo "   Instalando Composer..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer 2>/dev/null || {
    echo "   ⚠️  Falha ao instalar Composer"
  }
  chmod +x /usr/local/bin/composer
fi
composer --version
echo "✅ Composer OK"

# 6) Verificar se Git está disponível
echo "[6/15] 🔍 Verificando Git..."
if command -v git &> /dev/null; then
  git --version
  echo "✅ Git disponível"
else
  echo "⚠️  Git não disponível"
fi

# 7) Instalar plugin Amazon SES (somente se ainda não existir)
echo "[7/15] 📥 Instalando plugin Amazon SES..."
if [ ! -d "/var/www/html/docroot/plugins/AmazonSesBundle" ]; then
  echo "   Plugin não existe, instalando..."
  cd /var/www/html/docroot/plugins
  if command -v git &> /dev/null; then
    echo "   Usando Git..."
    git clone --depth 1 https://github.com/pm-pmaas/etailors_amazon_ses.git AmazonSesBundle 2>&1 | tail -5 || {
      echo "   ⚠️  Falha ao clonar plugin via git"
    }
  else
    echo "   Usando wget/curl..."
    wget -q https://github.com/pm-pmaas/etailors_amazon_ses/archive/master.zip -O amazon-ses.zip 2>/dev/null || {
      curl -sS -L https://github.com/pm-pmaas/etailors_amazon_ses/archive/master.zip -o amazon-ses.zip 2>/dev/null || {
        echo "   ⚠️  Falha ao baixar plugin"
      }
    }
    if [ -f "amazon-ses.zip" ]; then
      echo "   Extraindo..."
      unzip -q amazon-ses.zip
      mv etailors_amazon_ses-master AmazonSesBundle 2>/dev/null || true
      rm amazon-ses.zip
    fi
  fi
  chown -R www-data:www-data AmazonSesBundle 2>/dev/null || true
  echo "✅ Plugin instalado"
else
  echo "✅ Plugin já existe, pulando instalação"
fi

# 8) Instalar dependências PHP (AWS SDK) - apenas se não estiver presente
echo "[8/15] ☁️ Verificando AWS SDK..."
cd /var/www/html
if command -v composer &> /dev/null; then
  if ! composer show aws/aws-sdk-php --quiet 2>/dev/null; then
    echo "   Instalando AWS SDK..."
    composer require aws/aws-sdk-php \
      --no-interaction \
      --optimize-autoloader \
      --no-scripts \
      --no-dev 2>&1 | grep -E "(Installing|Using)" | tail -10 || {
      echo "   ⚠️  Erro ao instalar AWS SDK"
    }
    echo "✅ AWS SDK instalado"
  else
    echo "✅ AWS SDK já instalado, pulando"
  fi
else
  echo "⚠️  Composer não disponível"
fi

# 9) Atualizar autoloader (sempre, pois novos plugins podem ter sido adicionados)
echo "[9/15] 🔄 Atualizando autoloader..."
if command -v composer &> /dev/null; then
  composer dump-autoload --optimize --no-interaction 2>&1 | tail -3 || true
  echo "✅ Autoloader atualizado"
fi

# 10) Limpar cache
echo "[10/15] 🧹 Limpando cache..."
rm -rf /var/www/html/var/cache/prod 2>/dev/null || true
rm -rf /var/www/html/var/cache/dev 2>/dev/null || true
echo "✅ Cache limpo"

# 11) Recarregar plugins (ativa o AmazonSesBundle)
echo "[11/15] 🔌 Recarregando plugins..."
cd /var/www/html
php bin/console mautic:plugins:reload --env=prod 2>&1 | tail -5 || {
  echo "⚠️  Erro ao recarregar plugins"
}
echo "✅ Plugins recarregados"

# 12) Limpar cache novamente e aquecer
echo "[12/15] 🧹 Limpando cache (2ª vez)..."
php bin/console cache:clear --env=prod --no-warmup 2>&1 | tail -3 || true
php bin/console cache:warmup --env=prod 2>&1 | tail -3 || true
echo "✅ Cache aquecido"

# ============================================================
# 13) Configuração automática do Amazon SES (após instalação)
# ============================================================
echo "[13/15] 📧 Configurando Amazon SES..."

# Função para configurar via edição direta do local.php
configure_ses_via_file() {
  local local_php="/var/www/html/config/local.php"
  if [ ! -f "$local_php" ]; then
    echo "   ⚠️ Arquivo local.php não encontrado. Não é possível configurar via arquivo."
    return 1
  fi

  # Monta o DSN
  local DSN="mautic+ses+api://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@default?region=${AWS_REGION}&ratelimit=14"
  local FROM_EMAIL="${AWS_SES_FROM_EMAIL}"
  local FROM_NAME="${AWS_SES_FROM_NAME:-Mautic}"

  # Usa um script PHP inline para modificar o array de configuração
  php -r "
    \$configFile = '$local_php';
    \$config = include \$configFile;
    if (!is_array(\$config)) { \$config = []; }
    \$config['mailer_dsn'] = '$DSN';
    \$config['mailer_from_email'] = '$FROM_EMAIL';
    \$config['mailer_from_name'] = '$FROM_NAME';
    file_put_contents(\$configFile, '<?php return ' . var_export(\$config, true) . ';');
  " 2>/dev/null && {
    echo "   ✅ Configurações SES salvas diretamente no local.php"
    return 0
  } || {
    echo "   ⚠️ Falha ao escrever no local.php"
    return 1
  }
}

if [ -f /var/www/html/config/local.php ]; then
  echo "   Mautic instalado, aplicando configurações do SES..."

  # 1) Garante que o plugin está ativo
  php bin/console mautic:plugins:reload --env=prod > /dev/null 2>&1 && \
    echo "   ✅ Plugins recarregados (AmazonSesBundle ativado)" || \
    echo "   ⚠️ Falha ao recarregar plugins"

  # 2) Se as credenciais AWS estiverem definidas
  if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [ -n "$AWS_REGION" ]; then
    # Monta o DSN
    DSN="mautic+ses+api://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@default?region=${AWS_REGION}&ratelimit=14"

    # Tenta configurar via comando CLI (mautic:config:set)
    CONFIG_SET_AVAILABLE=$(php bin/console list mautic:config:set --env=prod 2>&1 | grep -c "mautic:config:set" || true)
    
    if [ "$CONFIG_SET_AVAILABLE" -gt 0 ]; then
      echo "   Usando comando mautic:config:set..."
      # Configura DSN
      php bin/console mautic:config:set mailer_dsn "$DSN" --env=prod > /dev/null 2>&1 && \
        echo "   ✅ Transporte SES configurado (DSN via comando)" || \
        { echo "   ⚠️ Falha ao configurar transporte via comando"; configure_ses_via_file; }
      
      # Configura e-mail from
      if [ -n "$AWS_SES_FROM_EMAIL" ]; then
        php bin/console mautic:config:set mailer_from_email "$AWS_SES_FROM_EMAIL" --env=prod > /dev/null 2>&1 && \
          echo "   ✅ Email 'from' configurado (via comando)" || \
          echo "   ⚠️ Falha ao configurar email 'from' via comando"
        
        php bin/console mautic:config:set mailer_from_name "${AWS_SES_FROM_NAME:-Mautic}" --env=prod > /dev/null 2>&1 && \
          echo "   ✅ Nome 'from' configurado (via comando)" || \
          echo "   ⚠️ Falha ao configurar nome 'from' via comando"
      fi
    else
      echo "   Comando mautic:config:set não disponível. Usando edição direta do local.php..."
      configure_ses_via_file
    fi
  else
    echo "   ⏩ Credenciais AWS não definidas. Configuração SES ignorada."
  fi
else
  echo "   ⏩ Mautic não instalado. Configuração SES será aplicada após a instalação (próximo restart)."
fi

# 14) Corrigir permissões finais
echo "[14/15] 🔐 Corrigindo permissões finais..."
chown -R www-data:www-data /var/www/html 2>/dev/null || true
chmod -R 755 /var/www/html 2>/dev/null || true
chmod -R 775 /var/www/html/var 2>/dev/null || true
chmod -R 775 /var/www/html/config 2>/dev/null || true
chmod -R 775 /var/www/html/media 2>/dev/null || true
echo "✅ Permissões finalizadas"

echo "================================================"
echo "[15/15] ✅ Setup completo! Iniciando Apache..."
echo "================================================"

# 15) Iniciar Apache
exec docker-php-entrypoint apache2-foreground
