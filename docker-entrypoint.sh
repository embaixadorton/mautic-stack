#!/usr/bin/env bash
set -e

echo "🚀 Iniciando Mautic com setup automático..."
echo "================================================"

# 1) Criar diretórios necessários
echo "[1/14] 📁 Criando diretórios..."
mkdir -p /var/www/html/config
mkdir -p /var/www/html/var/cache
mkdir -p /var/www/html/var/logs
mkdir -p /var/www/html/var/tmp
mkdir -p /var/www/html/media
mkdir -p /var/www/html/translations
mkdir -p /var/www/html/docroot/plugins
echo "✅ Diretórios criados"

# 2) Corrigir permissões
echo "[2/14] 🔐 Corrigindo permissões..."
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
echo "[3/14] ⏳ Aguardando MySQL em $MAUTIC_DB_HOST:$MAUTIC_DB_PORT..."
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

# ============================================================
# 4) Criar configuração do banco de dados (local.php) se não existir
# ============================================================
echo "[4/14] ⚙️ Pré-configurando banco de dados..."

if [ ! -f /var/www/html/config/local.php ]; then
  echo "   Arquivo local.php não encontrado. Criando com as configurações do .env..."
  
  # Escapa caracteres especiais na senha (se houver)
  DB_PASSWORD_ESCAPED=$(printf '%s' "$MAUTIC_DB_PASSWORD" | sed 's/[\/&]/\\&/g')

  cat > /var/www/html/config/local.php <<EOF
<?php
\$parameters = array(
    'db_driver' => '${DATABASE_DRIVER:-pdo_mysql}',
    'db_host' => '$MAUTIC_DB_HOST',
    'db_port' => '$MAUTIC_DB_PORT',
    'db_name' => '$MAUTIC_DB_NAME',
    'db_user' => '$MAUTIC_DB_USER',
    'db_password' => '$MAUTIC_DB_PASSWORD',
    'db_table_prefix' => null,
    'db_backup_tables' => true,
    'db_backup_prefix' => 'bak_',
);
EOF

  # Ajusta permissão
  chown www-data:www-data /var/www/html/config/local.php
  chmod 664 /var/www/html/config/local.php

  echo "   ✅ local.php criado com sucesso."
  echo "   Host: $MAUTIC_DB_HOST, Banco: $MAUTIC_DB_NAME, Usuário: $MAUTIC_DB_USER"
else
  echo "   ⏩ local.php já existe. Configuração de banco ignorada."
fi

# 5) Verificar se Composer está disponível
echo "[5/14] 🔧 Verificando Composer..."
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
echo "[6/14] 🔍 Verificando Git..."
if command -v git &> /dev/null; then
  git --version
  echo "✅ Git disponível"
else
  echo "⚠️  Git não disponível"
fi

# 7) Instalar plugin Amazon SES (somente se ainda não existir)
echo "[7/14] 📥 Instalando plugin Amazon SES..."
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
echo "[8/14] ☁️ Verificando AWS SDK..."
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

# 9) Atualizar autoloader
echo "[9/14] 🔄 Atualizando autoloader..."
if command -v composer &> /dev/null; then
  composer dump-autoload --optimize --no-interaction 2>&1 | tail -3 || true
  echo "✅ Autoloader atualizado"
fi

# 10) Limpar cache
echo "[10/14] 🧹 Limpando cache..."
rm -rf /var/www/html/var/cache/prod 2>/dev/null || true
rm -rf /var/www/html/var/cache/dev 2>/dev/null || true
echo "✅ Cache limpo"

# 11) Recarregar plugins (ativa o AmazonSesBundle)
echo "[11/14] 🔌 Recarregando plugins..."
cd /var/www/html
php bin/console mautic:plugins:reload --env=prod 2>&1 | tail -5 || {
  echo "⚠️  Erro ao recarregar plugins"
}
echo "✅ Plugins recarregados"

# 12) Limpar cache novamente e aquecer
echo "[12/14] 🧹 Limpando cache (2ª vez)..."
php bin/console cache:clear --env=prod --no-warmup 2>&1 | tail -3 || true
php bin/console cache:warmup --env=prod 2>&1 | tail -3 || true
echo "✅ Cache aquecido"

# 13) Corrigir permissões finais
echo "[13/14] 🔐 Corrigindo permissões finais..."
chown -R www-data:www-data /var/www/html 2>/dev/null || true
chmod -R 755 /var/www/html 2>/dev/null || true
chmod -R 775 /var/www/html/var 2>/dev/null || true
chmod -R 775 /var/www/html/config 2>/dev/null || true
chmod -R 775 /var/www/html/media 2>/dev/null || true
echo "✅ Permissões finalizadas"

echo "================================================"
echo "[14/14] ✅ Setup completo! Iniciando Apache..."
echo "================================================"

# 14) Iniciar Apache
exec docker-php-entrypoint apache2-foreground
