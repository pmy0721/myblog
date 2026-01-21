---
title: "MacOS+Hugo+阿里云｜搭建个人网站"
date: 2025-03-06T12:00:03+00:00
# weight: 2
# aliases: ["/first"]
tags: ["技术"]
author: "Me"
# author: ["Me", "You"] # multiple authors
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: false
# description: "Desc Text."
canonicalURL: "https://canonical.url/to/page"
disableHLJS: true # to disable highlightjs
disableShare: false
disableHLJS: false
hideSummary: false
searchHidden: true
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
ShowWordCount: true
ShowRssButtonInSectionTermList: true
UseHugoToc: true
cover:
    image: "<image path/url>" # image path/url
    alt: "<alt text>" # alt text
    caption: "<text>" # display caption under cover
    relative: false # when using page bundles set this to true
    hidden: true # only hide on current single page
# editPost:
#     URL: "https://github.com/<path_to_repo>/content"
#     Text: "Suggest Changes" # edit text
#     appendFilePath: true # to append file path to Edit link
---
> 💻设备信息：  
> MacBook Air M3

---

## 安装[Homebrew](https://brew.sh/zh-cn/)
>
> Homebrew 是一款专门为macOS设计的开源软件包管理工具

1. 下载最新的 [GitHub 发行版](https://github.com/Homebrew/brew/releases) 安装包，并进行安装
2. 设置环境变量，打开终端输入如下：

    ```bash
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)" #brew.idayer.com' >> ~/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
    ```

    参考自 [Homebrew 中文网](https://brew.idayer.com/guide/m1/)

3. 验证安装完毕

    ```bash
    brew --version
    ```

## 安装[Hugo](https://gohugo.io/)

1. 使用 `brew` 下载Hugo相关文件

    ```bash
    brew install hugo
    ```

2. 创建博客文件夹（站点）

    ```bash
    hugo new site myblog --format yaml
    ```

3. 下载 [PaperMod](https://github.com/adityatelange/hugo-PaperMod) 主题

    ```bash
    cd myblog
    git clone https://github.com/adityatelange/hugo-PaperMod themes/PaperMod --depth=1

    cd themes/PaperMod
    git pull
    ```

4. 打开 `myblog` 文件夹下的 `hugo.yaml`，添加：

    ```yaml
    theme: ["PaperMod"]
    ```

5. 创建新文章

    ```bash
    hugo new posts/first-blog.md
    ```

6. 本地浏览，地址为： <http://localhost:1313/>

    ```bash
    hugo server
    ```

7. 生成部署文件（public文件夹）

    ```bash
    hugo
    ```

## 部署在[阿里云服务器](https://ecs.console.aliyun.com/server/i-bp15a3cjq64huq2nwtpz/detail?regionId=cn-hangzhou)

1. 登录阿里云控制台，在 ECS 实例页面选择合适的配置创建实例，选择操作系统为 `Ubuntu`

2. 远程连接云服务器，在服务器中安装 `Web` 服务器软件，如 `Nginx` 或 `Apache`

    ```shell
    sudo apt-get update
    sudo apt-get install nginx
    ```

3. 配置安全组规则：在阿里云控制台的安全组设置中，添加规则允许 HTTP（80 端口）和 HTTPS（443 端口）的流量通过

4. 重置服务器密码，便于远程连接

5. 部署 Hugo 网站，上传网站文件：将本地 Hugo 项目生成的public目录下的所有文件上传到服务器。在`本地终端`中使用 SCP 命令，将文件上传到服务器中 Nginx 的默认网站目录/var/www/html/，需将username替换为服务器的用户名(一般为root)，server_ip替换为服务器的公网 IP 地址。

    ```bash
    scp -r public/* username@server_ip:/var/www/html/
    ```

6. 配置 Web 服务器：编辑 Nginx 或 Apache 的配置文件，设置虚拟主机。以 Nginx 为例，打开`/etc/nginx/sites-available/default`文件，配置server_name为你的域名，确保root指向 Hugo 网站文件所在目录。

7. 重启 Web 服务器：配置完成后，重启 Nginx 服务器使配置生效，命令为

    ```bash
    sudo service nginx restart
    ```

8. 在 Web 服务器中部署SSL证书，修改`/etc/nginx/`中的Nginx配置文件`nginx.conf`如下：   

    ```txt
    user www-data;
    worker_processes auto;
    pid /run/nginx.pid;
    include /etc/nginx/modules-enabled/*.conf;

    events {
        worker_connections 768;
        # multi_accept on;
    }

    http {

        ##
        # Basic Settings
        ##

        sendfile on;
        tcp_nopush on;
        types_hash_max_size 2048;
        # server_tokens off;

        # server_names_hash_bucket_size 64;
        # server_name_in_redirect off;

        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        ##
        # SSL Settings
        ##

        ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE
        ssl_prefer_server_ciphers on;

        ##
        # Logging Settings
        ##

        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log;

        ##
        # Gzip Settings
        ##

        gzip on;

        # gzip_vary on;
        # gzip_proxied any;
        # gzip_comp_level 6;
        # gzip_buffers 16 8k;
        # gzip_http_version 1.1;
        # gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

        ##
        # Virtual Host Configs
        ##
    
        server {
            listen 443 ssl;
            server_name mekeypan.com;

            ssl_certificate /etc/nginx/ssl/cert/mekeypan.com.pem;  # 公钥路径（相对或绝对）
            ssl_certificate_key /etc/nginx/ssl/cert/mekeypan.com.key; # 私钥路径

            # 加密协议优化
            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
            ssl_prefer_server_ciphers on;
            ssl_session_cache shared:SSL:10m;
            ssl_session_timeout 10m;

            # 其他网站配置（如根目录、代理等）
            location / {
                root /var/www/html;
                index index.html;
            }
        }

        # 可选：HTTP强制跳转HTTPS
        server {
            listen 80;
            server_name mekeypan.com;
            return 301 https://$host$request_uri;
        }

        include /etc/nginx/conf.d/*.conf;
        include /etc/nginx/sites-enabled/*;
 
    }

    #mail {
    #	# See sample authentication script at:
    #	# http://wiki.nginx.org/ImapAuthenticateWithApachePhpScript
    #
    #	# auth_http localhost/auth.php;
    #	# pop3
    ```
