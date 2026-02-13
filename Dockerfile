FROM mautic/mautic:5-apache

# Instalar extensão GD (para gráficos/imagens)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libavif15 \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev && \
    docker-php-ext-configure gd \
    --with-freetype \
    --with-jpeg && \
    docker-php-ext-install -j$(nproc) gd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copiar configuração personalizada do Apache (elimina aviso ServerName)
COPY apache-server.conf /etc/apache2/conf-available/
RUN a2enconf apache-server

# Copiar entrypoint customizado
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Usar o novo entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
