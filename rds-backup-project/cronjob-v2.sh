#!/bin/bash

# Variables de configuración
DB_HOST="your-rds-endpoint.us-east-1.rds.amazonaws.com"          # reemplaza con tu endpoint RDS
DB_NAME="your-db-name"
DB_USER="your-username"
DB_PASS="YourSecurePassword123!@#"
BUCKET="rds-backup-bucket"

# Fechas y nombres de archivo
DATE=$(date +%Y-%m-%d_%H-%M)
DUMP_NAME="backup-${DB_NAME}-${DATE}.sql"
COMPRESSED_NAME="${DUMP_NAME}.gz"
LOG_FILE="/var/log/rds-backup-${DATE}.log"

DUMP_PATH="/tmp/${DUMP_NAME}"
COMPRESSED_PATH="/tmp/${COMPRESSED_NAME}"

# Función para escribir logs
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========================================="
log "Inicio del respaldo de MySQL: $DATE"
log "Base de datos: $DB_NAME"

# Dump de MySQL
log "Realizando mysqldump..."
if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$DUMP_PATH"; then
  log "Dump completado: $DUMP_PATH"
else
  log "❌ Error durante mysqldump"
  aws s3 cp "$LOG_FILE" "s3://${BUCKET}/logs/$(basename "$LOG_FILE")"
  exit 1
fi

# Comprimir dump
log "Comprimiendo archivo..."
if gzip "$DUMP_PATH"; then
  log "Archivo comprimido: $COMPRESSED_PATH"
else
  log "❌ Error al comprimir el dump"
  aws s3 cp "$LOG_FILE" "s3://${BUCKET}/logs/$(basename "$LOG_FILE")"
  exit 1
fi

# Subir dump a S3
log "Subiendo respaldo a S3..."
if aws s3 cp "$COMPRESSED_PATH" "s3://${BUCKET}/backups/${COMPRESSED_NAME}"; then
  log "✅ Backup subido exitosamente a S3"
else
  log "❌ Error al subir el backup a S3"
  aws s3 cp "$LOG_FILE" "s3://${BUCKET}/logs/$(basename "$LOG_FILE")"
  exit 1
fi

# Limpiar dump local
log "Limpiando archivos temporales..."
rm -f "$COMPRESSED_PATH"

# Subir log a S3
log "Subiendo log a S3..."
aws s3 cp "$LOG_FILE" "s3://${BUCKET}/logs/$(basename "$LOG_FILE")"

log "✅ Proceso finalizado correctamente"
log "========================================="
