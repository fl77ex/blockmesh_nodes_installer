#!/bin/bash

# === НАСТРОЙКИ ===
CONTAINER_PREFIX="blockmesh-node"
DOCKER_IMAGE="blockmesh-cli"
DOCKERFILE_PATH="Dockerfile"  # Путь к Dockerfile
PROXY_FILE="proxies.txt"
ACCOUNT_FILE="accounts.txt"

# === ПРОВЕРКА DOCKER ===
if ! command -v docker &> /dev/null; then
    echo "Docker не установлен! Устанавливаем Docker..."
    apt update && apt install -y docker.io
    systemctl start docker
    systemctl enable docker
fi

# === СОЗДАНИЕ DOCKERFILE ===
cat <<EOF > "$DOCKERFILE_PATH"
# Используем Ubuntu 22.04
FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive

# Устанавливаем зависимости
RUN apt-get update && apt-get install -y \
    curl gzip git-all && rm -rf /var/lib/apt/lists/*

# Загружаем и устанавливаем Blockmesh CLI
WORKDIR /opt/
RUN curl -sLO https://github.com/block-mesh/block-mesh-monorepo/releases/latest/download/blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz \
    && tar -xvf blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz \
    && mv target/x86_64-unknown-linux-gnu/release/blockmesh-cli /usr/local/bin/blockmesh-cli \
    && chmod +x /usr/local/bin/blockmesh-cli

# Точка входа
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF

# === СОЗДАНИЕ ENTRYPOINT СКРИПТА ===
cat <<EOF > entrypoint.sh
#!/bin/bash
CONFIG_FILE="/opt/config.json"

if [ -f "\$CONFIG_FILE" ]; then
    EMAIL=$(jq -r '.email' \$CONFIG_FILE)
    PASSWORD=$(jq -r '.password' \$CONFIG_FILE)
    export HTTP_PROXY=$(jq -r '.http_proxy' \$CONFIG_FILE)
    export HTTPS_PROXY=$(jq -r '.https_proxy' \$CONFIG_FILE)
    
    echo "Запуск Blockmesh CLI с email: \$EMAIL"
    exec /usr/local/bin/blockmesh-cli --email "\$EMAIL" --password "\$PASSWORD"
else
    echo "Файл конфигурации не найден!"
    exit 1
fi
EOF

# === СБОРКА DOCKER-ОБРАЗА ===
echo "Собираем Docker-образ..."
docker build -t "$DOCKER_IMAGE" -f "$DOCKERFILE_PATH" .

# === ПРОВЕРКА ФАЙЛОВ ===
if [[ ! -f "$PROXY_FILE" || ! -f "$ACCOUNT_FILE" ]]; then
    echo "Файлы $PROXY_FILE или $ACCOUNT_FILE не найдены!"
    exit 1
fi

# Читаем файлы в массивы
mapfile -t PROXIES < "$PROXY_FILE"
mapfile -t ACCOUNTS < "$ACCOUNT_FILE"

# Проверяем, что в файлах достаточно данных
if [[ ${#PROXIES[@]} -ne ${#ACCOUNTS[@]} ]]; then
    echo "Количество прокси и аккаунтов не совпадает!"
    exit 1
fi

# Запуск контейнеров
for i in "${!PROXIES[@]}"; do
    PROXY=${PROXIES[$i]}
    ACCOUNT=${ACCOUNTS[$i]}
    
    IP=$(echo "$PROXY" | cut -d":" -f1)
    PORT=$(echo "$PROXY" | cut -d":" -f2)
    PROXY_USER=$(echo "$PROXY" | cut -d":" -f3)
    PROXY_PASS=$(echo "$PROXY" | cut -d":" -f4)
    
    EMAIL=$(echo "$ACCOUNT" | cut -d":" -f1)
    PASSWORD=$(echo "$ACCOUNT" | cut -d":" -f2)
    
    CONTAINER_NAME="${CONTAINER_PREFIX}-${i}"
    MACHINE_ID=$(uuidgen) # Генерируем уникальный Machine ID
    
    echo "Запускаем контейнер: $CONTAINER_NAME с email: $EMAIL через прокси: $IP:$PORT"
    
    CONFIG_JSON="/opt/config-${i}.json"
    cat <<CONFIG_EOF > "$CONFIG_JSON"
{
  "email": "$EMAIL",
  "password": "$PASSWORD",
  "http_proxy": "http://$PROXY_USER:$PROXY_PASS@$IP:$PORT",
  "https_proxy": "http://$PROXY_USER:$PROXY_PASS@$IP:$PORT"
}
CONFIG_EOF
    
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart=always \
        --hostname="$MACHINE_ID" \
        -v "$CONFIG_JSON:/opt/config.json" \
        "$DOCKER_IMAGE"

done

echo "Все ноды установлены и запущены!"
