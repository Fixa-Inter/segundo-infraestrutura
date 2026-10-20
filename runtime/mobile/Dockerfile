# Usa a imagem Java compilada do repositorio original, sem editar seu checkout.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
RUN apk add --no-cache python3 py3-boto3 \
    && addgroup -S fixa \
    && adduser -S -G fixa fixa \
    && mkdir -p /app/secrets \
    && chown fixa:fixa /app/secrets \
    && chmod 700 /app/secrets
COPY entrypoint.py /usr/local/bin/fixa-mobile-entrypoint.py
USER fixa
ENTRYPOINT ["python3", "/usr/local/bin/fixa-mobile-entrypoint.py"]
CMD ["sh", "-c", "exec java -Dserver.port=${PORT:-8080} -jar /app/app.jar"]
