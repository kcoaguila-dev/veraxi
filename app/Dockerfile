# Stage 1: Build the Flutter Web App
# Flutter 3.50.1 (Dart 3.14.0) from the official archive, SHA256-verified.
# Do NOT go back to ghcr.io/cirruslabs/flutter:stable: that image is
# stalled at Flutter 3.44.0 (Dart 3.12.0), below the pubspec.lock floor
# (Dart >=3.13.0, Flutter >=3.47.0), so `flutter pub get` fails there.
FROM ubuntu:24.04 AS build-env

ARG FLUTTER_VERSION=3.50.1
ARG FLUTTER_SHA256=4ad17fc8462fbcef2ba19ff4a78c0a16b7147fde1add8578e267ea62cdb92678
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl file git unzip xz-utils zip ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
    && tar -xf /tmp/flutter.tar.xz -C /opt && rm /tmp/flutter.tar.xz \
    && git config --global --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter --version

# Set working directory
WORKDIR /app

# Copy dependency files first to cache dependencies
COPY pubspec.* ./
RUN flutter pub get

# Copy the rest of the application
COPY . .

# Add build arg for self-hosted mode
ARG IS_SELF_HOSTED=true
ARG AUTH_ENABLED=true
ARG IS_ENTERPRISE=false
ARG API_URL=/api

# Build the web application (outputs to /app/build/web)
RUN flutter build web --release --dart-define=IS_SELF_HOSTED=$IS_SELF_HOSTED --dart-define=AUTH_ENABLED=$AUTH_ENABLED --dart-define=IS_ENTERPRISE=$IS_ENTERPRISE --dart-define=API_URL=$API_URL

# Stage 2: Serve the app with Nginx
FROM nginx:alpine

# Copy custom Nginx configuration for Flutter routing
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy the built Flutter web files from Stage 1
COPY --from=build-env /app/build/web /usr/share/nginx/html

# Expose port 80
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
