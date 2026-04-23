#!/bin/bash
#==============================================================================
# APIPark Jenkins 自动化部署脚本
# 用途: 用于 Jenkins Freestyle 项目自动化部署 APIPark
#
# 使用方式:
#   ./jenkins-deploy.sh [命令] [选项]
#
# 命令:
#   full-install    - 完整安装（首次部署）
#   update-apipark  - 仅更新 APIPark 服务（代码更新后使用）
#   status          - 查看服务状态
#   stop            - 停止所有服务
#   start           - 启动所有服务
#   info            - 显示访问信息
#
# 配置方式:
#   1. 环境变量: export APIPARK_PORT=8080 && ./jenkins-deploy.sh full-install
#   2. 配置文件: 复制 .env.example 为 .env，修改后执行脚本
#==============================================================================

set -e

#=======================================
# 配置文件加载
#=======================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载 .env 配置文件（如果存在）
if [ -f "${SCRIPT_DIR}/.env" ]; then
    echo "[INFO] 加载配置文件: ${SCRIPT_DIR}/.env"
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

#=======================================
# 配置区域 - 请根据你的环境修改
#=======================================
# 镜像配置
APIPARK_IMAGE="${APIPARK_IMAGE:-apipark/apipark:latest}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"  # 如使用私有仓库，填写仓库地址

# 端口配置
APIPARK_PORT="${APIPARK_PORT:-18288}"
MYSQL_PORT="${MYSQL_PORT:-33306}"
REDIS_PORT="${REDIS_PORT:-6379}"
INFLUXDB_PORT="${INFLUXDB_PORT:-8086}"
APINTO_PROXY_PORT="${APINTO_PROXY_PORT:-8099}"
APINTO_ADMIN_PORT="${APINTO_ADMIN_PORT:-9400}"

# 密码配置（建议通过 .env 文件配置）
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-apipark_mysql_123}"
REDIS_PASSWORD="${REDIS_PASSWORD:-apipark_redis_123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123456}"

# 数据目录
DATA_DIR="${DATA_DIR:-/var/lib/apipark}"
NETWORK_NAME="apipark-net"

# 容器名称
APIPARK_CONTAINER="apipark"
MYSQL_CONTAINER="apipark-mysql"
REDIS_CONTAINER="apipark-redis"
INFLUXDB_CONTAINER="apipark-influxdb"
APINTO_CONTAINER="apipark-apinto"
LOKI_CONTAINER="apipark-loki"
NSQ_CONTAINER="apipark-nsq"
GRAFANA_CONTAINER="apipark-grafana"

#=======================================
# 辅助函数
#=======================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    if ! docker ps &> /dev/null; then
        log_error "Docker 服务未运行或当前用户无权限"
        log_info "请执行: sudo usermod -aG docker \$USER"
        exit 1
    fi
    log_success "Docker 检查通过"
}

get_arch() {
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then
        echo "amd64"
    elif [ "$ARCH" == "aarch64" ]; then
        echo "arm64"
    else
        log_error "不支持的架构: $ARCH"
        exit 1
    fi
}

get_local_ip() {
    hostname -I | awk '{print $1}'
}

get_external_ip() {
    curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "$(get_local_ip)"
}

wait_for_container() {
    local container=$1
    local cmd=$2
    local max_wait=60
    local count=0
    
    log_info "等待 ${container} 启动..."
    while ! docker exec ${container} ${cmd} &> /dev/null; do
        count=$((count + 1))
        if [ $count -ge $max_wait ]; then
            log_error "${container} 启动超时"
            return 1
        fi
        sleep 2
    done
    log_success "${container} 已就绪"
}

#=======================================
# 网络管理
#=======================================
init_network() {
    local exists=$(docker network ls --filter "name=^${NETWORK_NAME}$" --format "{{.Name}}")
    if [ -n "$exists" ]; then
        log_info "Docker 网络 ${NETWORK_NAME} 已存在"
        return
    fi
    
    log_info "创建 Docker 网络 ${NETWORK_NAME}..."
    docker network create --driver bridge --subnet 172.100.0.0/24 --gateway 172.100.0.1 ${NETWORK_NAME}
    log_success "网络创建成功"
}

#=======================================
# 容器安装函数
#=======================================
install_mysql() {
    local exists=$(docker ps -a --filter "name=^/${MYSQL_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "MySQL 容器已存在，跳过安装"
        return
    fi
    
    log_info "安装 MySQL..."
    mkdir -p ${DATA_DIR}/mysql
    
    docker run -dt \
        --name ${MYSQL_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p ${MYSQL_PORT}:3306 \
        -v ${DATA_DIR}/mysql:/var/lib/mysql \
        -e MYSQL_DATABASE=apipark \
        -e MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD} \
        mysql:8.0.37 \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci
    
    wait_for_container ${MYSQL_CONTAINER} "mysqladmin -u root -p${MYSQL_ROOT_PASSWORD} ping"
    log_success "MySQL 安装完成"
}

install_redis() {
    local exists=$(docker ps -a --filter "name=^/${REDIS_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "Redis 容器已存在，跳过安装"
        return
    fi
    
    log_info "安装 Redis..."
    
    docker run -dt \
        --name ${REDIS_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p ${REDIS_PORT}:6379 \
        redis:7.2.4 \
        bash -c "redis-server --protected-mode yes --logfile redis.log --appendonly no --port 6379 --requirepass ${REDIS_PASSWORD}"
    
    wait_for_container ${REDIS_CONTAINER} "redis-cli ping"
    log_success "Redis 安装完成"
}

install_influxdb() {
    local exists=$(docker ps -a --filter "name=^/${INFLUXDB_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "InfluxDB 容器已存在，跳过安装"
        return
    fi
    
    log_info "安装 InfluxDB..."
    mkdir -p ${DATA_DIR}/influxdb
    
    docker run -dt \
        --name ${INFLUXDB_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p ${INFLUXDB_PORT}:8086 \
        -v ${DATA_DIR}/influxdb:/var/lib/influxdb2 \
        -e DOCKER_INFLUXDB_INIT_USERNAME=admin \
        -e DOCKER_INFLUXDB_INIT_PASSWORD=Key123qaz \
        -e DOCKER_INFLUXDB_INIT_ORG=apipark \
        -e DOCKER_INFLUXDB_INIT_BUCKET=apinto \
        -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=dQ9>fK6&gJ \
        -e DOCKER_INFLUXDB_INIT_MODE=setup \
        influxdb:2.6
    
    wait_for_container ${INFLUXDB_CONTAINER} "curl -s -o /dev/null http://localhost:8086/"
    log_success "InfluxDB 安装完成"
}

install_nsq() {
    local exists=$(docker ps -a --filter "name=^/${NSQ_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "NSQ 容器已存在，跳过安装"
        return
    fi
    
    log_info "安装 NSQ..."
    mkdir -p ${DATA_DIR}/nsq
    
    docker run -dt \
        --name ${NSQ_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p 4150:4150 -p 4151:4151 \
        -v ${DATA_DIR}/nsq:/data \
        nsqio/nsq:latest \
        /nsqd --data-path=/data
    
    wait_for_container ${NSQ_CONTAINER} "nsqd --version"
    log_success "NSQ 安装完成"
}

install_loki() {
    local exists=$(docker ps -a --filter "name=^/${LOKI_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "Loki 容器已存在，跳过安装"
        return
    fi
    
    log_info "安装 Loki..."
    mkdir -p ${DATA_DIR}/loki
    
    # 写入 Loki 配置
    cat > ${DATA_DIR}/loki/loki-config.yml << 'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
  grpc_listen_port: 9096
common:
  instance_addr: 127.0.0.1
  path_prefix: /tmp/loki
  storage:
    filesystem:
      chunks_directory: /tmp/loki/chunks
      rules_directory: /tmp/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
EOF
    
    docker run -dt \
        --name ${LOKI_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p 3100:3100 \
        -v ${DATA_DIR}/loki:/mnt/config \
        grafana/loki:latest \
        -config.file=/mnt/config/loki-config.yml
    
    wait_for_container ${LOKI_CONTAINER} "loki --version"
    log_success "Loki 安装完成"
}

install_apipark() {
    log_info "安装/更新 APIPark..."

    # 停止并删除旧容器
    local exists=$(docker ps -a --filter "name=^/${APIPARK_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "停止并移除旧的 APIPark 容器..."
        docker rm -f ${APIPARK_CONTAINER}
    fi

    # 如果有私有仓库，加上前缀
    local image="${APIPARK_IMAGE}"
    if [ -n "${DOCKER_REGISTRY}" ]; then
        image="${DOCKER_REGISTRY}/${APIPARK_IMAGE}"
        docker pull ${image}
    else
        docker pull ${image}
    fi

    docker run -dt \
        --name ${APIPARK_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p ${APIPARK_PORT}:8288 \
        -e MYSQL_USER_NAME=root \
        -e MYSQL_PWD=${MYSQL_ROOT_PASSWORD} \
        -e MYSQL_IP=${MYSQL_CONTAINER} \
        -e MYSQL_PORT=3306 \
        -e MYSQL_DB=apipark \
        -e ERROR_DIR=work/logs \
        -e ERROR_FILE_NAME=error.log \
        -e ERROR_LOG_LEVEL=info \
        -e ERROR_EXPIRE=7d \
        -e ERROR_PERIOD=day \
        -e REDIS_ADDR=${REDIS_CONTAINER}:6379 \
        -e REDIS_PWD=${REDIS_PASSWORD} \
        -e NSQ_ADDR=${NSQ_CONTAINER}:4150 \
        -e ADMIN_PASSWORD=${ADMIN_PASSWORD} \
        ${image}

    sleep 5
    wait_for_container ${APIPARK_CONTAINER} "curl -s -o /dev/null http://127.0.0.1:8288/"
    log_success "APIPark 安装完成"
}

install_apinto() {
    local exists=$(docker ps -a --filter "name=^/${APINTO_CONTAINER}$" --format "{{.Names}}")
    if [ -n "$exists" ]; then
        log_info "Apinto 容器已存在，跳过安装"
        return
    fi

    log_info "安装 Apinto Gateway..."
    mkdir -p ${DATA_DIR}/apinto/data ${DATA_DIR}/apinto/log

    # 获取 IP 地址
    local LAN_IP=$(get_local_ip)
    local EXTERNAL_IP=$(get_external_ip)

    # 写入配置文件
    mkdir -p ${DATA_DIR}/apinto
    cat > ${DATA_DIR}/apinto/config.yml << EOF
version: 2
client:
  advertise_urls:
    - http://${LAN_IP}:9400
  listen_urls:
    - http://0.0.0.0:9400
gateway:
  advertise_urls:
    - http://${EXTERNAL_IP}:8099
    - http://${LAN_IP}:8099
  listen_urls:
    - http://0.0.0.0:8099
peer:
  listen_urls:
    - http://0.0.0.0:9401
  advertise_urls:
    - http://${LAN_IP}:9401
EOF

    docker run -dt \
        --name ${APINTO_CONTAINER} \
        --restart=always \
        --privileged=true \
        --network=${NETWORK_NAME} \
        -p ${APINTO_ADMIN_PORT}:9400 \
        -p 9401:9401 \
        -p ${APINTO_PROXY_PORT}:8099 \
        -v ${DATA_DIR}/apinto/config.yml:/etc/apinto/config.yml \
        -v ${DATA_DIR}/apinto/data:/var/lib/apinto \
        -v ${DATA_DIR}/apinto/log:/var/log/apinto \
        eolinker/apinto-gateway \
        ./start.sh

    wait_for_container ${APINTO_CONTAINER} "curl -s -o /dev/null http://localhost:9400/"
    log_success "Apinto Gateway 安装完成"
}

#=======================================
# 配置初始化
#=======================================
init_apipark_config() {
    log_info "初始化 APIPark 配置..."

    local LAN_IP=$(get_local_ip)
    local EXTERNAL_IP=$(get_external_ip)
    local ADMIN_PASSWORD="${ADMIN_PASSWORD}"

    # 登录获取 Cookie
    log_info "登录 APIPark..."
    local response=$(curl -s -i -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}" \
        "http://${LAN_IP}:${APIPARK_PORT}/api/v1/account/login/username")

    local cookie=$(echo "$response" | grep -i "Set-Cookie" | sed 's/Set-Cookie: //;s/;.*//')

    # 设置集群
    log_info "设置集群配置..."
    curl -s -X PUT \
        -H "Content-Type: application/json" \
        -H "Cookie: $cookie" \
        -d "{\"manager_address\":\"http://${LAN_IP}:9400\"}" \
        "http://${LAN_IP}:${APIPARK_PORT}/api/v1/cluster/reset" > /dev/null

    # 设置 InfluxDB
    log_info "设置 InfluxDB 配置..."
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Cookie: $cookie" \
        -d "{\"driver\":\"influxdb-v2\",\"config\":{\"addr\":\"http://${INFLUXDB_CONTAINER}:8086\",\"org\":\"apipark\",\"token\":\"dQ9>fK6&gJ\"}}" \
        "http://${LAN_IP}:${APIPARK_PORT}/api/v1/monitor/config" > /dev/null

    # 设置 Loki
    log_info "设置 Loki 配置..."
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Cookie: $cookie" \
        -d "{\"config\":{\"url\":\"http://${LAN_IP}:3100\"}}" \
        "http://${LAN_IP}:${APIPARK_PORT}/api/v1/log/loki" > /dev/null

    # 设置 OpenAPI 地址
    log_info "设置 OpenAPI 地址..."
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Cookie: $cookie" \
        -d "{\"site_prefix\":\"http://${EXTERNAL_IP}:${APIPARK_PORT}\"}" \
        "http://${LAN_IP}:${APIPARK_PORT}/api/v1/system/general" > /dev/null

    log_success "APIPark 配置初始化完成"
}

#=======================================
# 主命令
#=======================================
full_install() {
    log_info "========== 开始完整安装 APIPark =========="
    check_docker
    init_network

    install_mysql
    install_redis
    install_influxdb
    install_nsq
    install_loki
    install_apipark
    install_apinto
    init_apipark_config

    log_success "========== APIPark 安装完成 =========="
    print_info
}

update_apipark() {
    log_info "========== 更新 APIPark 服务 =========="
    check_docker

    # 检查依赖服务
    local mysql_running=$(docker ps --filter "name=^/${MYSQL_CONTAINER}$" --format "{{.Names}}")
    if [ -z "$mysql_running" ]; then
        log_error "MySQL 未运行，请先执行完整安装"
        exit 1
    fi

    install_apipark
    log_success "========== APIPark 更新完成 =========="
}

status() {
    log_info "========== 服务状态 =========="
    echo ""
    docker ps --filter "name=apipark" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "无运行中的容器"
    echo ""
}

stop_all() {
    log_info "停止所有服务..."
    for container in ${APIPARK_CONTAINER} ${APINTO_CONTAINER} ${INFLUXDB_CONTAINER} ${NSQ_CONTAINER} ${LOKI_CONTAINER} ${REDIS_CONTAINER} ${MYSQL_CONTAINER}; do
        docker stop ${container} 2>/dev/null || true
    done
    log_success "所有服务已停止"
}

start_all() {
    log_info "启动所有服务..."
    for container in ${MYSQL_CONTAINER} ${REDIS_CONTAINER} ${INFLUXDB_CONTAINER} ${NSQ_CONTAINER} ${LOKI_CONTAINER} ${APIPARK_CONTAINER} ${APINTO_CONTAINER}; do
        docker start ${container} 2>/dev/null || true
    done
    log_success "所有服务已启动"
}

print_info() {
    local LAN_IP=$(get_local_ip)
    local EXTERNAL_IP=$(get_external_ip)

    echo ""
    echo "=============================================="
    echo "       APIPark 部署信息"
    echo "=============================================="
    echo ""
    echo "🌐 访问地址:"
    echo "   内网: http://${LAN_IP}:${APIPARK_PORT}"
    echo "   外网: http://${EXTERNAL_IP}:${APIPARK_PORT}"
    echo ""
    echo "👤 管理员账号:"
    echo "   用户名: admin"
    echo "   密码: ${ADMIN_PASSWORD}"
    echo ""
    echo "📊 其他服务:"
    echo "   MySQL: ${LAN_IP}:${MYSQL_PORT}"
    echo "   Redis: ${LAN_IP}:${REDIS_PORT}"
    echo "   InfluxDB: http://${LAN_IP}:${INFLUXDB_PORT}"
    echo "   Apinto Gateway: http://${LAN_IP}:${APINTO_PROXY_PORT}"
    echo ""
    echo "=============================================="
}

#=======================================
# 入口
#=======================================
case "$1" in
    full-install)
        full_install
        ;;
    update-apipark)
        update_apipark
        ;;
    status)
        status
        ;;
    stop)
        stop_all
        ;;
    start)
        start_all
        ;;
    info)
        print_info
        ;;
    *)
        echo "用法: $0 {full-install|update-apipark|status|stop|start|info}"
        echo ""
        echo "命令说明:"
        echo "  full-install    - 完整安装（首次部署）"
        echo "  update-apipark  - 仅更新 APIPark 服务"
        echo "  status          - 查看服务状态"
        echo "  stop            - 停止所有服务"
        echo "  start           - 启动所有服务"
        echo "  info            - 打印访问信息"
        exit 1
        ;;
esac

