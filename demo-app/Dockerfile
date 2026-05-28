FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
ARG BUILD_SHA=unknown
RUN sed -i "s/BUILD_SHA_PLACEHOLDER/${BUILD_SHA}/" /usr/share/nginx/html/index.html
EXPOSE 80
