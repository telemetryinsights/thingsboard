# Use Maven with Java 17
FROM maven:3.8.6-eclipse-temurin-17 as build

# Install Node.js (Angular UI needs it)
RUN curl -fsSL https://deb.nodesource.com/setup_16.x | bash - && \
    apt-get update && \
    apt-get install -y nodejs

# Set working directory
WORKDIR /app

# Copy entire ThingsBoard repo into container
COPY . .

# Force Git to use HTTPS instead of SSH
RUN git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"

# Build Angular UI
RUN mvn clean install -f ui-ngx/pom.xml -DskipTests -Dlicense.skip=true

# Build main app only (skip microservices)
RUN mvn clean install -f pom.xml -DskipTests -Dlicense.skip=true -pl ui-ngx,application -am