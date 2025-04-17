#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BLOG_REPO="https://gitee.com/linhaojun/aurora.git"
BLOG_SOURCE_DIR="aurora_blog_source"
MYSQL_PASSWORD="123456"
REDIS_PASSWORD="123456"
RABBITMQ_USER="guest"
RABBITMQ_PASSWORD="guest"
MINIO_USER="minioadmin"
MINIO_PASSWORD="minioadmin"
MINIO_BUCKET="aurora"
PUBLIC_IP=$(curl -X POST https://kangxianghui.top/karl-openapi/Utils/GetIp)

check_system() {
    echo -e "${YELLOW}[1/19] 正在检查系统支持...${NC}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(echo "$VERSION_ID" | grep -oE '^[0-9]+(\.[0-9]+)?')
    elif [ -f /etc/centos-release ]; then
        OS="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/centos-release)
    else
        echo -e "${RED}错误：不支持的操作系统！仅支持 Ubuntu 和 CentOS。${NC}"
        exit 1
    fi
    case "$OS" in
    ubuntu)
        if ! [[ "$OS_VERSION" =~ ^(18|20|22|24)\.04 ]]; then
            echo -e "${RED}错误：仅支持 Ubuntu LTS 版本 (18.04/20.04/22.04/24.04)${NC}"
            exit 1
        fi
        ;;
    centos)
        if ! [[ "$OS_VERSION" =~ ^(7|8|9)(\..*)?$ ]]; then
            echo -e "${RED}错误：仅支持 CentOS 7/8/9${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}错误：不支持的操作系统 [$OS]！仅支持 Ubuntu 和 CentOS。${NC}"
        exit 1
        ;;
    esac
    ARCH=$(uname -m)
    if ! [[ "$ARCH" =~ ^(x86_64|aarch64|arm64)$ ]]; then
        echo -e "${RED}警告：未经测试的架构 [$ARCH]，建议使用 x86_64 或 ARM64。${NC}"
    fi
    echo -e "${GREEN}✓ 系统检测通过: ${OS} ${OS_VERSION} (${ARCH})${NC}"
}

update_system() {
    echo -e "${YELLOW}[2/19] 正在更新系统依赖...${NC}"
    if [ "$OS" = "ubuntu" ]; then
        apt-get update -y && apt-get upgrade -y
    else
        yum update -y && yum upgrade -y
    fi
}

install_git() {
    echo -e "${YELLOW}[3/19] 正在检查/安装Git...${NC}"
    if command -v git &>/dev/null; then
        echo -e "${GREEN}Git已安装，跳过...${NC}"
    else
        if [ "$OS" = "ubuntu" ]; then
            apt-get install -y git
        else
            yum install -y git
        fi
    fi
}

clone_repo() {
    echo -e "${YELLOW}[4/19] 正在获取博客源码...${NC}"
    while true; do
        if [ -d "$BLOG_SOURCE_DIR" ]; then
            echo -e "${GREEN}源码目录已存在，跳过克隆...${NC}"
            return 0
        fi
        read -p "请输入GitHub上的博客仓库地址(直接回车默认：$BLOG_REPO): " input_repo
        BLOG_REPO=${input_repo:-$BLOG_REPO}
        if [ -z "$BLOG_REPO" ]; then
            echo -e "${RED}错误：仓库地址不能为空！${NC}"
            continue
        fi
        if [[ "$BLOG_REPO" != *.git ]]; then
            echo -e "${YELLOW}警告：仓库地址通常以.git结尾，您输入的地址可能不正确。${NC}"
            read -p "您确定要使用这个地址吗？(y/n): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        echo -e "${BLUE}正在克隆仓库: $BLOG_REPO ...${NC}"
        if git clone "$BLOG_REPO" "$BLOG_SOURCE_DIR"; then
            echo -e "${GREEN}仓库克隆成功！${NC}"
            return 0
        else
            echo -e "${RED}克隆仓库失败！请检查以下可能原因：${NC}"
            echo -e "1. 仓库地址是否正确"
            echo -e "2. 您是否有访问权限"
            echo -e "3. 网络连接是否正常"
            read -p "是否要重新输入仓库地址？(y/n): " retry
            if [[ ! "$retry" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    done
}

install_docker() {
    echo -e "${YELLOW}[5/19] 正在检查/安装Docker...${NC}"
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}Docker已安装，跳过...${NC}"
    else
        if [ "$OS" = "ubuntu" ]; then
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo apt-key add -
            sudo add-apt-repository "deb [arch=amd64] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable"
            sudo apt-get update
            sudo apt-get install docker-ce docker-ce-cli containerd.io
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Docker安装成功！${NC}"
            else
                echo -e "${RED}Docker安装失败！${NC}"
                exit 1
            fi
        else
            yum install -y yum-utils device-mapper-persistent-data lvm2
            yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            yum -y install docker-ce
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Docker安装成功！${NC}"
            else
                echo -e "${RED}Docker安装失败！${NC}"
                exit 1
            fi
        fi
        systemctl start docker
        systemctl enable docker
    fi
}

config_docker_mirror() {
    echo -e "${YELLOW}[6/19] 正在配置Docker镜像加速...${NC}"
    if [ ! -f "/etc/docker/daemon.json" ]; then
        mkdir -p /etc/docker
        sudo tee /etc/docker/daemon.json <<-'EOF'
{
    "registry-mirrors": [
        "https://docker.1ms.run/",
        "https://docker.xuanyuan.me/"
    ]
}
EOF
        systemctl daemon-reload
        systemctl restart docker
        echo -e "${GREEN}Docker镜像加速配置完成！${NC}"
    else
        echo -e "${GREEN}Docker镜像加速已配置，跳过...${NC}"
    fi
}

install_mysql() {
    echo -e "${YELLOW}[7/19] 正在安装MySQL...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -q 'aurora-mysql-container'; then
        echo -e "${GREEN}MySQL容器已存在，跳过...${NC}"
    else
        read -p "请输入MySQL密码(直接回车默认：$MYSQL_PASSWORD): " input_pass
        MYSQL_PASSWORD=${input_pass:-$MYSQL_PASSWORD}
        mysql_version="8.0.39-debian"
        if [ "$(docker images -q mysql:$mysql_version 2>/dev/null)" == "" ]; then
            echo -e "${BLUE}正在拉取MySQL镜像: mysql:$mysql_version ...${NC}"
            sudo docker pull mysql:$mysql_version
            if [ $? -ne 0 ]; then
                echo -e "${RED}MySQL镜像拉取失败！${NC}"
                exit 1
            fi
            echo -e "${GREEN}MySQL镜像拉取成功！${NC}"
        fi
        echo -e "${BLUE}正在启动MySQL容器...${NC}"
        docker run -d \
            --name aurora-mysql-container \
            -e MYSQL_ROOT_PASSWORD=$MYSQL_PASSWORD \
            -p 3306:3306 \
            -v /data/mysql:/var/lib/mysql \
            --restart always \
            mysql:$mysql_version
        sleep 30
        echo -e "${GREEN}MySQL容器启动成功！${NC}"
    fi
}

init_database() {
    echo -e "${YELLOW}[8/19] 正在初始化数据库...${NC}"
    local sql_file="${BLOG_SOURCE_DIR}/aurora-springboot/sql/aurora.sql"
    if [ -f "$sql_file" ]; then
        if [ "$(docker exec aurora-mysql-container mysql -uroot -p$MYSQL_PASSWORD -e 'SHOW DATABASES;' | grep -q 'aurora' && echo 'true' || echo 'false')" = "true" ]; then
            echo -e "${GREEN}数据库已存在，跳过创建...${NC}"
        else
            docker exec aurora-mysql-container mysql -uroot -p$MYSQL_PASSWORD \
                -e "CREATE DATABASE aurora CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
            echo -e "${GREEN}数据库创建成功！${NC}"
            # 初始化数据库
            if ! docker exec -i aurora-mysql-container mysql -uroot -p"$MYSQL_PASSWORD" aurora <"$sql_file"; then
                echo -e "${RED}数据库初始化失败！${NC}"
                exit 1
            fi
            echo -e "${GREEN}数据库初始化完成！${NC}"
        fi
    else
        echo -e "${YELLOW}未找到SQL初始化文件，跳过数据库初始化...${NC}"
    fi
}

install_redis() {
    echo -e "${YELLOW}[9/19] 正在安装Redis...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -q 'aurora-redis-container'; then
        echo -e "${GREEN}Redis容器已存在，跳过...${NC}"
    else
        read -p "请输入Redis密码(直接回车默认：$REDIS_PASSWORD): " input_pass
        REDIS_PASSWORD=${input_pass:-$REDIS_PASSWORD}
        redis_version="7.0.13"
        if [ "$(docker images -q redis:$redis_version 2>/dev/null)" == "" ]; then
            echo -e "${BLUE}正在拉取Redis镜像: redis:$redis_version ...${NC}"
            sudo docker pull redis:$redis_version
            if [ $? -ne 0 ]; then
                echo -e "${RED}Redis镜像拉取失败！${NC}"
                exit 1
            fi
            echo -e "${GREEN}Redis镜像拉取成功！${NC}"
        fi
        echo -e "${BLUE}正在启动Redis容器...${NC}"
        docker run -d \
            --name aurora-redis-container \
            -e REDIS_PASSWORD=$REDIS_PASSWORD \
            -p 6379:6379 \
            --restart always \
            redis:$redis_version /bin/sh -c 'redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}'
        echo -e "${GREEN}Redis容器启动成功！${NC}"
    fi
}

install_rabbitmq() {
    echo -e "${YELLOW}[10/19] 正在安装RabbitMQ...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -q 'aurora-rabbitmq-container'; then
        echo -e "${GREEN}RabbitMQ容器已存在，跳过...${NC}"
    else
        read -p "请输入RabbitMQ用户名(直接回车默认：$RABBITMQ_USER): " input_user
        RABBITMQ_USER=${input_user:-$RABBITMQ_USER}
        read -p "请输入RabbitMQ密码(默认:guest): " input_pass
        RABBITMQ_PASSWORD=${input_pass:-$RABBITMQ_PASSWORD}
        rabbitmq_version="3.12.14"
        if [ "$(docker images -q rabbitmq:$rabbitmq_version 2>/dev/null)" == "" ]; then
            echo -e "${BLUE}正在拉取RabbitMQ镜像: rabbitmq:$rabbitmq_version ...${NC}"
            sudo docker pull rabbitmq:$rabbitmq_version-management
            if [ $? -ne 0 ]; then
                echo -e "${RED}RabbitMQ镜像拉取失败！${NC}"
                exit 1
            fi
            echo -e "${GREEN}RabbitMQ镜像拉取成功！${NC}"
        fi
        echo -e "${BLUE}正在启动RabbitMQ容器...${NC}"
        docker run -d \
            --name aurora-rabbitmq-container \
            -e RABBITMQ_DEFAULT_USER=$RABBITMQ_USER \
            -e RABBITMQ_DEFAULT_PASS=$RABBITMQ_PASSWORD \
            -p 5672:5672 \
            -p 15672:15672 \
            --restart always \
            rabbitmq:$rabbitmq_version-management
        echo -e "${GREEN}RabbitMQ容器启动成功！${NC}"
    fi
}

install_minio() {
    echo -e "${YELLOW}[11/19] 正在安装MinIO...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -q 'aurora-minio-container'; then
        echo -e "${GREEN}MinIO容器已存在，跳过...${NC}"
    else
        read -p "请输入MinIO用户名(直接回车默认：$MINIO_USER): " input_user
        MINIO_USER=${input_user:-$MINIO_USER}
        read -p "请输入MinIO密码(直接回车默认：$MINIO_PASSWORD): " input_pass
        MINIO_PASSWORD=${input_pass:-$MINIO_PASSWORD}
        if [ "$(docker images -q minio/minio 2>/dev/null)" == "" ]; then
            echo -e "${BLUE}正在拉取MinIO镜像: minio/minio ...${NC}"
            sudo docker pull minio/minio
            if [ $? -ne 0 ]; then
                echo -e "${RED}MinIO镜像拉取失败！${NC}"
                exit 1
            fi
            echo -e "${GREEN}MinIO镜像拉取成功！${NC}"
        fi
        echo -e "${BLUE}正在启动MinIO容器...${NC}"
        docker run -d \
            --name aurora-minio-container \
            -p 9000:9000 \
            -p 9001:9001 \
            -e "MINIO_ROOT_USER=$MINIO_USER" \
            -e "MINIO_ROOT_PASSWORD=$MINIO_PASSWORD" \
            -v /data/minio:/data \
            --restart always \
            minio/minio server /data --console-address ":9001" --address ":9000"
        sleep 15
        echo -e "${GREEN}MinIO容器启动成功！${NC}"
    fi
}

init_minio_bucket() {
    echo -e "${YELLOW}[12/19] 正在初始化MinIO桶...${NC}"
    minio_myname="myminio"
    docker exec -it aurora-minio-container mc alias set $minio_myname http://localhost:9000 $MINIO_USER $MINIO_PASSWORD
    if docker exec -it aurora-minio-container mc ls $minio_myname | grep -q "$MINIO_BUCKET"; then
        echo -e "${GREEN}MinIO桶已存在，跳过...${NC}"
    else
        read -p "请输入MinIO桶名称(直接回车默认：$MINIO_BUCKET): " input_bucket
        MINIO_BUCKET=${input_bucket:-$MINIO_BUCKET}
        docker exec -it aurora-minio-container mc mb $minio_myname/$MINIO_BUCKET
        docker exec -it aurora-minio-container mc anonymous set public $minio_myname/$MINIO_BUCKET
        echo -e "${GREEN}MinIO桶初始化完成！${NC}"
    fi
}

install_maven() {
    echo -e "${YELLOW}[13/19] 正在检查/安装Maven...${NC}"
    if command -v mvn &>/dev/null; then
        echo -e "${GREEN}Maven已安装，跳过...${NC}"
    else
        maven_version="3.5.0"
        if [ "$OS" = "ubuntu" ]; then
            apt-get install -y maven
        else
            yum install -y maven
        fi
        if ! command -v mvn &>/dev/null; then
            echo -e "${RED}Maven安装失败！${NC}"
            exit 1
        fi
        echo -e "${GREEN}Maven安装成功！${NC}"
    fi
}

config_maven() {
    echo -e "${YELLOW}[14/19] 正在配置Maven...${NC}"
    HOME=$(eval echo "~$USER")
    if [ ! -d "$HOME/.m2" ]; then
        mkdir -p $HOME/.m2
    fi
    if [ ! -f "$HOME/.m2/settings.xml" ]; then
        cat >$HOME/.m2/settings.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <localRepository> ${HOME}/.m2/repository</localRepository>

  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>central</mirrorOf>
      <name>aliyun_maven</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>

</settings>
EOF
        echo -e "${GREEN}Maven配置成功！${NC}"
    else
        echo -e "${GREEN}Maven配置已存在，跳过...${NC}"
    fi
}

build_backend() {
    echo -e "${YELLOW}[15/19] 正在构建后端...${NC}"
    cd $BLOG_SOURCE_DIR/aurora-springboot || {
        echo -e "${RED}后端目录不存在！${NC}"
        exit 1
    }
    if [ -f "src/main/resources/application.yml" ]; then
        mv src/main/resources/application.yml src/main/resources/application_back.yml
    fi
    cp ../../application.yml src/main/resources/application.yml
    if [ $? -ne 0 ]; then
        echo -e "${RED}拷贝application.yml失败！${NC}"
        exit 1
    fi
    if [ -f "target/aurora-springboot-0.0.1.jar" ]; then
        echo -e "${GREEN}后端服务已构建，跳过...${NC}"
    else
        mvn clean package -DskipTests || {
            echo -e "${RED}后端构建失败！${NC}"
            exit 1
        }
        echo -e "${GREEN}后端构建成功！${NC}"
    fi
    SERVER_NAME=aurora-springboot-0.0.1.jar
    TAG=latest
    SERVER_PORT=8080
    CID=$(docker ps | grep "$SERVER_NAME" | awk '{print $1}')
    IID=$(docker images | grep "$SERVER_NAME" | awk '{print $3}')
    if [ -n "$CID" ]; then
        echo "存在后端服务容器$SERVER_NAME,CID-$CID"
        docker stop $CID
        echo "成功停止后端服务容器$SERVER_NAME,CID-$CID"
        docker rm $CID
        echo "成功删除后端服务容器$SERVER_NAME,CID-$CID"
    fi
    if [ -n "$IID" ]; then
        echo "存在后端服务镜像$SERVER_NAME:$TAG,IID=$IID"
        docker rmi $IID
        echo "成功删除后端服务镜像$SERVER_NAME:$TAG,IID=$IID"
    fi
    echo "开始构建后端服务镜像$SERVER_NAME:$TAG"
    docker builder prune -f
    docker build --no-cache -t $SERVER_NAME:$TAG .
    echo "成功构建后端服务镜像$SERVER_NAME:$TAG"
    docker run -d \
        --name $SERVER_NAME \
        -p $SERVER_PORT:$SERVER_PORT \
        -e SPRING_DATASOURCE_URL="jdbc:mysql://$PUBLIC_IP:3306/aurora?serverTimezone=Asia/Shanghai&allowMultiQueries=true" \
        -e SPRING_DATASOURCE_USERNAME="root" \
        -e SPRING_DATASOURCE_PASSWORD="$MYSQL_PASSWORD" \
        -e SPRING_REDIS_HOST="$PUBLIC_IP" \
        -e SPRING_REDIS_PASSWORD="$REDIS_PASSWORD" \
        -e SPRING_RABBITMQ_HOST="$PUBLIC_IP" \
        -e SPRING_RABBITMQ_USERNAME="$RABBITMQ_USER" \
        -e SPRING_RABBITMQ_PASSWORD="$RABBITMQ_PASSWORD" \
        -e SEARCH_MODEL="mysql" \
        -e UPLOAD_MODEL="minio" \
        -e UPLOAD_MINIO_URL="http://$PUBLIC_IP/minio/" \
        -e UPLOAD_MINIO_ENDPOINT="http://$PUBLIC_IP:9000" \
        -e UPLOAD_MINIO_ACCESSKEY="$MINIO_USER" \
        -e UPLOAD_MINIO_SECRETKEY="$MINIO_PASSWORD" \
        -e UPLOAD_MINIO_BUCKETNAME="$MINIO_BUCKET" \
        -e WEBSITE_URL="http://$PUBLIC_IP" \
        --restart always \
        $SERVER_NAME:$TAG
    if [ $? -ne 0 ]; then
        echo -e "${RED}后端服务容器启动失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}后端服务容器启动成功！${NC}"
    cd ../.. || {
        echo -e "${RED}返回目录失败！${NC}"
        exit 1
    }
}

install_nodejs() {
    echo -e "${YELLOW}[16/19] 正在安装Node.js...${NC}"
    if command -v node &>/dev/null; then
        echo -e "${GREEN}Node.js已安装，跳过...${NC}"
    else
        apt-get install -y nodejs
        if [ "$OS" = "centos" ]; then
            yum install -y nodejs
        fi
        if ! command -v node &>/dev/null; then
            echo -e "${RED}Node.js安装失败！${NC}"
            exit 1
        fi
        echo -e "${GREEN}Node.js安装成功！${NC}"
    fi
}

install_npm() {
    echo -e "${YELLOW}[17/19] 正在检查npm...${NC}"
    if command -v npm &>/dev/null; then
        echo -e "${GREEN}npm已安装，跳过...${NC}"
    else
        if [ "$OS" = "ubuntu" ]; then
            apt-get install -y npm
        else
            yum install -y npm
        fi
        if ! command -v npm &>/dev/null; then
            echo -e "${RED}npm安装失败！${NC}"
            exit 1
        fi
        echo -e "${GREEN}npm安装成功！${NC}"
    fi
}

config_npm_source() {
    echo -e "${YELLOW}[18/19] 正在配置npm安装源...${NC}"
    npm config set registry "https://registry.npmmirror.com"
    if [ $? -ne 0 ]; then
        echo -e "${RED}npm安装源配置失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}npm安装源配置成功！${NC}"
}

build_frontend() {
    echo -e "${YELLOW}[18/19] 正在构建前端...${NC}"
    cd $BLOG_SOURCE_DIR/aurora-vue || {
        echo -e "${RED}前端目录不存在！${NC}"
        exit 1
    }
    if [ -f "nginx.conf.template" ]; then
        mv nginx.conf.template nginx_back.conf.template
    fi
    cp ../../nginx.conf.template nginx.conf.template
    if [ $? -ne 0 ]; then
        echo -e "${RED}拷贝nginx.conf失败！${NC}"
        exit 1
    fi
    BLOG_DIR_PATH=aurora-blog
    ADMIN_DIR_PATH=aurora-admin
    if [ ! -d "$BLOG_DIR_PATH" ]; then
        echo -e "${RED}错误：$BLOG_DIR_PATH 目录不存在！${NC}"
        exit 1
    fi
    if [ -d "$BLOG_DIR_PATH/dist" ]; then
        echo -e "${GREEN}博客前端已构建，跳过...${NC}"
    else
        echo -e "${BLUE}正在构建博客前端...${NC}"
        cd $BLOG_DIR_PATH
        if [ "$(grep -c '<!-- <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests" \/> -->' public/index.html)" -eq 0 ]; then
            sed -i 's/<meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests" \/>/<!-- <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests" \/> -->/' public/index.html
        fi
        npm install || {
            echo -e "${RED}博客前端依赖安装失败！${NC}"
            exit 1
        }
        npm run build || {
            echo -e "${RED}博客前端构建失败！${NC}"
            exit 1
        }
        echo -e "${GREEN}博客前端构建成功！${NC}"
        cd ..
    fi
    if [ ! -d "$ADMIN_DIR_PATH" ]; then
        echo -e "${RED}错误：$ADMIN_DIR_PATH 目录不存在！${NC}"
        exit 1
    fi
    if [ -d "$ADMIN_DIR_PATH/dist" ]; then
        echo -e "${GREEN}管理后台前端已构建，跳过...${NC}"
    else
        echo -e "${BLUE}正在构建管理后台前端...${NC}"
        cd $ADMIN_DIR_PATH
        if [ "$(grep -c '<!-- <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests" \/> -->' public/index.html)" -eq 0 ]; then
            sed -i 's/<meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests" \/>/<!-- <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests" \/> -->/' public/index.html
        fi
        if [ "$(grep -c 'base: '\''admin'\''\,' src/router/index.js)" -eq 0 ]; then
            sed -i 's/new VueRouter({/new VueRouter({\n    base: "admin",/' src/router/index.js
        fi
        if [ "$(grep -c 'publicPath: process.env.NODE_ENV === '\''production'\'' ? '\''/admin'\'' : '\''/'\''', vue.config.js)" -eq 0 ]; then
            sed -i "s/defineConfig({/defineConfig({\n  publicPath: process.env.NODE_ENV === 'production' ? '\/admin' : '\/',/" vue.config.js
        fi
        npm install || {
            echo -e "${RED}管理后台前端依赖安装失败！${NC}"
            exit 1
        }
        npm run build || {
            echo -e "${RED}管理后台前端构建失败！${NC}"
            exit 1
        }
        echo -e "${GREEN}管理后台前端构建成功！${NC}"
        cd ..
    fi
    SERVER_NAME=aurora-blog
    TAG=latest
    SERVER_PORT=80
    CID=$(docker ps | grep "$SERVER_NAME" | awk '{print $1}')
    IID=$(docker images | grep "$SERVER_NAME" | awk '{print $3}')
    if [ -n "$CID" ]; then
        echo "存在前端服务容器$SERVER_NAME,CID-$CID"
        docker stop $CID
        echo "成功停止前端服务容器$SERVER_NAME,CID-$CID"
        docker rm $CID
        echo "成功删除前端服务容器$SERVER_NAME,CID-$CID"
    fi
    if [ -n "$IID" ]; then
        echo "存在前端服务镜像$SERVER_NAME:$TAG,IID=$IID"
        docker rmi $IID
        echo "成功删除前端服务镜像$SERVER_NAME:$TAG,IID=$IID"
    fi
    echo "开始构建前端服务镜像$SERVER_NAME:$TAG"
    docker builder prune -f
    docker build --no-cache -t $SERVER_NAME:$TAG .
    echo "成功构建前端服务镜像$SERVER_NAME:$TAG"
    docker run -d \
        --name $SERVER_NAME \
        -p $SERVER_PORT:$SERVER_PORT \
        -v $(pwd)/nginx.conf.template:/etc/nginx/templates/default.conf.template \
        -e PORT=$SERVER_PORT \
        -e HOSTNAME=$PUBLIC_IP \
        -e API_PORT="8080" \
        -e MINIO_PORT="9000" \
        -e MINIO_BUCKET=$MINIO_BUCKET \
        --restart always \
        $SERVER_NAME:$TAG
    if [ $? -ne 0 ]; then
        echo -e "${RED}前端服务容器启动失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}前端服务容器启动成功！${NC}"
    cd ../.. || {
        echo -e "${RED}返回目录失败！${NC}"
        exit 1
    }
}

print_info() {
    echo -e "${YELLOW}[19/19] 正在打印访问信息...${NC}"
    echo -e "${GREEN}=============================================="
    echo -e "所有服务已成功部署！"
    echo -e "=============================================="
    echo -e "MySQL信息:"
    echo -e "地址: $PUBLIC_IP:3306"
    echo -e "用户名: root"
    echo -e "密码: $MYSQL_PASSWORD"
    echo -e "----------------------------------------------"
    echo -e "Redis信息:"
    echo -e "地址: $PUBLIC_IP:6379"
    echo -e "密码: $REDIS_PASSWORD"
    echo -e "----------------------------------------------"
    echo -e "RabbitMQ信息:"
    echo -e "地址: $PUBLIC_IP:15672"
    echo -e "用户名: $RABBITMQ_USER"
    echo -e "密码: $RABBITMQ_PASSWORD"
    echo -e "----------------------------------------------"
    echo -e "MinIO信息:"
    echo -e "地址: $PUBLIC_IP:9001"
    echo -e "用户名: $MINIO_USER"
    echo -e "密码: $MINIO_PASSWORD"
    echo -e "桶名称: $MINIO_BUCKET"
    echo -e "----------------------------------------------"

    echo -e "博客访问地址: http://$PUBLIC_IP"

    echo -e "后台管理地址: http://$PUBLIC_IP/admin"
    echo -e "用户名: admin@163.com"
    echo -e "密码: 123456"

    echo -e "=============================================="
    echo -e "服务器安全组、防火墙等设置请确保以上端口开放，否则无法访问！"
    echo -e "Aurora博客已部署完成！请根据上述信息访问您的博客和相关服务。"

    echo -e "作者: 花未眠"
    echo -e "脚本作者: karl${NC}"
}

main() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本需要以root权限运行！${NC}"
        exit 1
    fi
    check_system
    update_system
    install_git
    clone_repo
    install_docker
    config_docker_mirror
    install_mysql
    init_database
    install_redis
    install_rabbitmq
    install_minio
    init_minio_bucket
    install_maven
    config_maven
    build_backend
    install_nodejs
    install_npm
    config_npm_source
    build_frontend
    print_info
}

main
