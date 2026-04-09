#!/bin/bash

# =========================================
# Script de Restauración de RDS desde S3
# =========================================

# Variables de configuración para la instancia RDS
DB_HOST="${RDS_ENDPOINT:-your-rds-endpoint.us-east-1.rds.amazonaws.com}"
DB_NAME="${DB_NAME:-your-db-name}"
DB_USER="${DB_USER:-your-username}"
DB_PASS="${DB_PASSWORD:-YourSecurePassword123!@#}"
BUCKET="${S3_BUCKET:-rds-backup-bucket}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Configuración del backup a restaurar
BACKUP_DATE="${1:-2024-03-15_10-30}"  # Puede pasarse como parámetro
BACKUP_NAME="rds-backup-bucket-${BACKUP_DATE}.sql.gz"

# Rutas y archivos temporales
DATE=$(date +%Y-%m-%d_%H-%M-%S)
RESTORE_LOG="/var/log/rds-restore-${DATE}.log"
TEMP_DIR="/tmp/restore-${DATE}"
COMPRESSED_PATH="${TEMP_DIR}/${BACKUP_NAME}"
DUMP_PATH="${TEMP_DIR}/rds-backup-bucket-${BACKUP_DATE}.sql"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para escribir logs
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

log_success() {
    echo -e "${GREEN}✓${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

log_error() {
    echo -e "${RED}✗${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

# Función para limpiar archivos temporales
cleanup() {
    log "Limpiando archivos temporales..."
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_success "Archivos temporales eliminados"
    fi
}

# Función para subir logs a S3
upload_log() {
    local status=$1
    log "Subiendo log de restauración a S3..."
    if aws s3 cp "$RESTORE_LOG" "s3://${BUCKET}/restore-logs/${status}/$(basename "$RESTORE_LOG")" \
        --region "$AWS_REGION" 2>/dev/null; then
        log_success "Log subido a S3: s3://${BUCKET}/restore-logs/${status}/$(basename "$RESTORE_LOG")"
    else
        log_warning "No se pudo subir el log a S3"
    fi
}

# Manejo de errores
error_exit() {
    log_error "Error: $1"
    upload_log "failed"
    cleanup
    exit 1
}

# Trap para limpiar en caso de interrupción
trap cleanup EXIT

# Validar prerequisitos
check_prerequisites() {
    log "Verificando prerequisitos..."
    
    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI no está instalado"
    fi
    
    # Verificar MySQL client
    if ! command -v mysql &> /dev/null; then
        error_exit "MySQL client no está instalado"
    fi
    
    # Verificar credenciales AWS
    if ! aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
        error_exit "Credenciales AWS no configuradas o inválidas"
    fi
    
    log_success "Todos los prerequisitos cumplidos"
}

# Función principal de restauración
main() {
    log "========================================="
    log "Inicio de restauración de MySQL: $DATE"
    log "Base de datos destino: $DB_NAME"
    log "Host RDS: $DB_HOST"
    log "Backup a restaurar: $BACKUP_NAME"
    log "========================================="

    # Verificar prerequisitos
    check_prerequisites

    # Crear directorio temporal
    log "Creando directorio temporal..."
    mkdir -p "$TEMP_DIR" || error_exit "No se pudo crear el directorio temporal"
    log_success "Directorio temporal creado: $TEMP_DIR"

    # Verificar que el backup existe en S3
    log "Verificando que el backup existe en S3..."
    if ! aws s3 ls "s3://${BUCKET}/backups/${BACKUP_NAME}" --region "$AWS_REGION" > /dev/null 2>&1; then
        error_exit "El backup $BACKUP_NAME no existe en S3"
    fi
    log_success "Backup encontrado en S3"

    # Obtener tamaño del backup
    BACKUP_SIZE=$(aws s3 ls "s3://${BUCKET}/backups/${BACKUP_NAME}" --region "$AWS_REGION" \
        --summarize | grep "Total Size" | awk '{print $3}')
    log "Tamaño del backup: $(numfmt --to=iec-i --suffix=B ${BACKUP_SIZE:-0})"

    # Descargar backup desde S3
    log "Descargando backup desde S3..."
    if aws s3 cp "s3://${BUCKET}/backups/${BACKUP_NAME}" "$COMPRESSED_PATH" \
        --region "$AWS_REGION" --no-progress; then
        log_success "Backup descargado: $COMPRESSED_PATH"
    else
        error_exit "Error al descargar el backup desde S3"
    fi

    # Verificar integridad del archivo descargado
    if [[ ! -f "$COMPRESSED_PATH" ]] || [[ ! -s "$COMPRESSED_PATH" ]]; then
        error_exit "El archivo descargado está vacío o no existe"
    fi

    # Verificar conectividad con la instancia RDS
    log "Verificando conectividad con la instancia RDS..."
    if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
        --connect-timeout=10 -e "SELECT 1;" > /dev/null 2>&1; then
        error_exit "No se puede conectar a la instancia RDS. Verifica host, usuario y contraseña"
    fi
    log_success "Conexión a RDS establecida"

    # Descomprimir backup
    log "Descomprimiendo backup..."
    if gunzip -k "$COMPRESSED_PATH" 2>/dev/null; then
        log_success "Backup descomprimido: $DUMP_PATH"
    else
        error_exit "Error al descomprimir el backup"
    fi

    # Verificar tamaño del archivo descomprimido
    DUMP_SIZE=$(stat -c%s "$DUMP_PATH" 2>/dev/null || stat -f%z "$DUMP_PATH" 2>/dev/null)
    log "Tamaño del dump SQL: $(numfmt --to=iec-i --suffix=B ${DUMP_SIZE:-0})"

    # Crear base de datos si no existe
    log "Verificando/creando base de datos destino..."
    if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
        -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
        log_success "Base de datos '$DB_NAME' lista"
    else
        error_exit "Error al crear/verificar la base de datos"
    fi

    # Obtener número de tablas antes de la restauración
    TABLES_BEFORE=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME';" -s -N 2>/dev/null || echo "0")
    log "Tablas existentes antes de la restauración: $TABLES_BEFORE"

    # Realizar la restauración
    log "Iniciando restauración de la base de datos..."
    log_warning "Este proceso puede tomar varios minutos dependiendo del tamaño del backup"
    
    START_TIME=$(date +%s)
    
    # Usar pv si está disponible para mostrar progreso
    if command -v pv &> /dev/null && [[ -n "$DUMP_SIZE" ]]; then
        pv "$DUMP_PATH" | mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null
        RESTORE_STATUS=$?
    else
        mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$DUMP_PATH" 2>/dev/null
        RESTORE_STATUS=$?
    fi
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    if [[ $RESTORE_STATUS -eq 0 ]]; then
        log_success "Restauración completada en $(date -d@$DURATION -u +%H:%M:%S)"
    else
        error_exit "Error durante la restauración de la base de datos"
    fi

    # Verificar que la restauración fue exitosa
    log "Verificando la restauración..."
    TABLE_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME';" -s -N 2>/dev/null || echo "0")
    
    TABLES_ADDED=$((TABLE_COUNT - TABLES_BEFORE))

    if [[ $TABLE_COUNT -gt 0 ]]; then
        log_success "Verificación exitosa: $TABLE_COUNT tablas totales ($TABLES_ADDED nuevas)"
        
        # Mostrar algunas estadísticas adicionales
        ROW_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" \
            -e "SELECT SUM(table_rows) FROM information_schema.tables WHERE table_schema = '$DB_NAME';" -s -N 2>/dev/null || echo "0")
        log "Filas aproximadas restauradas: $(numfmt --to=si ${ROW_COUNT:-0})"
    else
        log_warning "No se encontraron tablas en la base de datos restaurada"
    fi

    # Limpiar archivos temporales
    cleanup

    # Subir log de restauración a S3
    upload_log "success"

    log "========================================="
    log_success "Proceso de restauración finalizado correctamente"
    log "Base de datos restaurada: $DB_NAME en $DB_HOST"
    log "========================================="

    # Mostrar estadísticas finales
    log "=== ESTADÍSTICAS DE RESTAURACIÓN ==="
    log "Backup utilizado: $BACKUP_NAME"
    log "Fecha de restauración: $DATE"
    log "Duración: $(date -d@$DURATION -u +%H:%M:%S)"
    log "Tablas restauradas: $TABLE_COUNT"
    log "Nuevas tablas: $TABLES_ADDED"
    log "Log guardado en: s3://${BUCKET}/restore-logs/success/$(basename "$RESTORE_LOG")"
    log "========================================="
}

# Ejecutar función principal
main "$@"