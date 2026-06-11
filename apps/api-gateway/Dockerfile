FROM nginx:1.27-alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY proxy_params.conf /etc/nginx/proxy_params.conf

# Non-root: create nginx user dirs
RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx \
 && chmod -R 755 /var/cache/nginx

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s \
  CMD wget -qO- http://localhost/health || exit 1

LABEL maintainer="devops@hybe.com" \
      service="api-gateway" \
      version="1.0.0"
