# syntax=docker/dockerfile:1
#
# Образ приложения «Доска объявлений» (Spring Boot + React Admin).
# Сборка многоступенчатая: фронтенд (Vite) -> бэкенд (Gradle, bootJar) -> рантайм на JRE.
#
# BASE_REGISTRY — откуда брать базовые образы. По умолчанию mirror.gcr.io/library:
# это публичное зеркало Docker Hub, оно не упирается в rate limit и доступно и локально, и в CI.
# Для Docker Hub напрямую: --build-arg BASE_REGISTRY=docker.io/library
ARG BASE_REGISTRY=mirror.gcr.io/library

# --- 1. Фронтенд ---------------------------------------------------------------
FROM ${BASE_REGISTRY}/node:24-alpine AS frontend
WORKDIR /frontend
COPY app/frontend/package.json app/frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/frontend/ ./
RUN npm run build

# --- 2. Бэкенд -----------------------------------------------------------------
FROM ${BASE_REGISTRY}/eclipse-temurin:27-jdk AS backend
WORKDIR /app
# Сначала только обёртка Gradle и описание сборки — этот слой кешируется между сборками кода
COPY app/gradlew app/settings.gradle.kts app/build.gradle.kts ./
COPY app/gradle ./gradle
RUN chmod +x gradlew && ./gradlew --no-daemon --quiet dependencies > /dev/null
COPY app/src ./src
# Собранный фронтенд отдаётся самим Spring Boot как статика
COPY --from=frontend /frontend/dist/ ./src/main/resources/static/
RUN ./gradlew --no-daemon bootJar -x test \
    && cp build/libs/*-SNAPSHOT.jar /app/app.jar

# --- 3. Рантайм ----------------------------------------------------------------
FROM ${BASE_REGISTRY}/eclipse-temurin:27-jre-alpine
WORKDIR /app

RUN addgroup -S app && adduser -S -G app -u 10001 app \
    && apk add --no-cache curl
COPY --from=backend /app/app.jar /app/app.jar
USER 10001

ENV SPRING_PROFILES_ACTIVE=prod \
    MANAGEMENT_SERVER_PORT=9090 \
    JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# 8080 — трафик приложения, 9090 — actuator (health-пробы и метрики Prometheus)
EXPOSE 8080 9090

HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:9090/actuator/health/readiness || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
