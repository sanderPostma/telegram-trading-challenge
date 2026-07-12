FROM nginx:1.27

COPY patterns_server/nginx.conf /etc/nginx/conf.d/default.conf
COPY config/telegram_patterns.yaml /usr/share/nginx/html/telegram_patterns.yaml

EXPOSE 80
