# Stage 1: Build the Flutter Web App
FROM ghcr.io/cirruslabs/flutter:3.24.0 AS build-env

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

# Build the web application (outputs to /app/build/web)
RUN flutter build web --release --dart-define=IS_SELF_HOSTED=$IS_SELF_HOSTED --dart-define=AUTH_ENABLED=$AUTH_ENABLED

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
