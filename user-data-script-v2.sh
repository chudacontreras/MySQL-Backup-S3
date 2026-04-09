#!/bin/bash
# ============================================================================
# RDS MySQL Backup System - User Data Script v2
# Copyright (C) 2024 Aelis4 Project Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# ============================================================================

# Script User Data para configuración automática de la instancia EC2
# Este script se ejecuta automáticamente al lanzar la instancia

# Variables de configuración (reemplazar con valores reales)
export RDS_ENDPOINT="your-rds-endpoint.cluster-xxx.us-east-1.rds.amazonaws.com"
export RDS_USERNAME="admin"
export RDS_PASSWORD="your-secure-password"
export DATABASE_NAME="myapp"
export S3_BUCKET_NAME="your-backup-bucket-name"
export AWS_REGION="us-east-1"
export LOG_GROUP="/aws/rds-backup/mysql"

# Logging de inicio
echo "$(date '+%Y-%m-%d %H:%M:%S') - Iniciando configuración de instancia RDS Backup" >> /var/log/cloud-init-output.log

# Actualizar el sistema
yum update -y

# Instalar dependencias necesarias
yum install -y mysql awscli cronie amazon-cloudwatch-agent

# Configurar timezone a Eastern Time (donde está Virginia)
timedatectl set-timezone America/New_York

# Crear directorios necesarios
mkdir -p /opt/rds-backup
mkdir -p /var/log/rds-backup
chmod 755 /opt/rds-backup
chmod 755 /var/log/rds-backup

# Crear script principal de backup
cat > /opt/rds-backup/mysql_backup.sh << 'EOF'
#!/bin/bash

# Script para realizar backup de MySQL RDS y subirlo a S3
# Configuración de variables de entorno
source /opt/rds-backup/env_vars.sh

# Variables de backup
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${DATABASE_NAME}_backup_${BACKUP_DATE}.sql"
BACKUP_PATH="/tmp/${BACKUP_FILE}"
LOG_FILE="/var/log/rds-backup/backup_${BACKUP_DATE}.log"

# Función de logging mejorada
log_message() {
    local MESSAGE="$1"
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${TIMESTAMP} - ${MESSAGE}" | tee -a ${LOG_FILE}
    
    # Enviar también a CloudWatch Logs
    aws logs put-log-events \
        --log-group-name ${LOG_GROUP} \
        --log-stream-name $(hostname) \
        --log-events timestamp=$(date +%s000),message="${TIMESTAMP} - ${MESSAGE}" \
        --region ${AWS_REGION} 2>/dev/null || true
}

# Función para verificar prerrequisitos
check_prerequisites() {
    log_message "Verificando prerrequisitos..."
    
    # Verificar conectividad a RDS
    if ! mysql -h ${RDS_ENDPOINT} -u ${RDS_USERNAME} -p${RDS_PASSWORD} -e "SELECT 1;" 2>/dev/null; then
        log_message "ERROR: No se puede conectar a la base de datos RDS"
        return 1
    fi
    
    # Verificar que la base de datos existe
    if ! mysql -h ${RDS_ENDPOINT} -u ${RDS_USERNAME} -p${RDS_PASSWORD} -e "USE ${DATABASE_NAME};" 2>/dev/null; then
        log_message "ERROR: La base de datos ${DATABASE_NAME} no existe"
        return 1
    fi
    
    # Verificar acceso a S3
    if ! aws s3 ls s3://${S3_BUCKET_NAME}/ --region ${AWS_REGION} >/dev/null 2>&1; then
        log_message "ERROR: No se puede acceder al bucket S3: ${S3_BUCKET_NAME}"
        return 1
    fi
    
    log_message "Todos los prerrequisitos verificados correctamente"
    return 0
}

# Función para limpiar archivos temporales
cleanup() {
    if [ -f "${BACKUP_PATH}" ]; then
        rm -f "${BACKUP_PATH}"
        log_message "Archivo temporal limpiado: ${BACKUP_PATH}"
    fi
    if [ -f "${BACKUP_PATH}.gz" ]; then
        rm -f "${BACKUP_PATH}.gz"
        log_message "Archivo temporal comprimido limpiado: ${BACKUP_PATH}.gz"
    fi
}

# Función para manejar errores
handle_error() {
    log_message "ERROR: El backup falló en el paso: $1"
    cleanup
    exit 1
}

# Función principal de backup
perform_backup() {
    log_message "=== Iniciando proceso de backup ==="
    log_message "Base de datos: ${DATABASE_NAME}"
    log_message "RDS Endpoint: ${RDS_ENDPOINT}"
    log_message "Bucket S3: ${S3_BUCKET_NAME}"
    log_message "Fecha de backup: ${BACKUP_DATE}"
    
    # Verificar prerrequisitos
    if ! check_prerequisites; then
        handle_error "Verificación de prerrequisitos"
    fi
    
    # Realizar dump de la base de datos
    log_message "Ejecutando mysqldump..."
    
    mysqldump -h ${RDS_ENDPOINT} \
             -u ${RDS_USERNAME} \
             -p${RDS_PASSWORD} \
             --single-transaction \
             --routines \
             --triggers \
             --events \
             --hex-blob \
             --quick \
             --lock-tables=false \
             --add-drop-database \
             --add-drop-table \
             --create-options \
             --disable-keys \
             --extended-insert \
             --set-charset \
             ${DATABASE_NAME} > ${BACKUP_PATH} 2>/dev/null
    
    if [ $? -eq 0 ]; then
        local BACKUP_SIZE=$(stat -f%z "${BACKUP_PATH}" 2>/dev/null || stat -c%s "${BACKUP_PATH}")
        log_message "Mysqldump completado exitosamente. Tamaño: ${BACKUP_SIZE} bytes"
    else
        handle_error "Mysqldump"
    fi
    
    # Comprimir el archivo
    log_message "Comprimiendo archivo de backup..."
    gzip ${BACKUP_PATH}
    
    if [ $? -eq 0 ]; then
        BACKUP_PATH="${BACKUP_PATH}.gz"
        BACKUP_FILE="${BACKUP_FILE}.gz"
        local COMPRESSED_SIZE=$(stat -f%z "${BACKUP_PATH}" 2>/dev/null || stat -c%s "${BACKUP_PATH}")
        log_message "Compresión completada. Tamaño comprimido: ${COMPRESSED_SIZE} bytes"
    else
        handle_error "Compresión"
    fi
    
    # Subir a S3
    local S3_KEY="mysql-backups/$(date +%Y)/$(date +%m)/${BACKUP_FILE}"
    log_message "Subiendo backup a S3: s3://${S3_BUCKET_NAME}/${S3_KEY}"
    
    aws s3 cp ${BACKUP_PATH} s3://${S3_BUCKET_NAME}/${S3_KEY} \
        --metadata "database=${DATABASE_NAME},backup-date=${BACKUP_DATE},instance=$(hostname),script-version=1.0" \
        --storage-class STANDARD_IA \
        --region ${AWS_REGION}
    
    if [ $? -eq 0 ]; then
        log_message "Backup subido exitosamente a S3"
        
        # Verificar la subida
        S3_SIZE=$(aws s3api head-object \
                    --bucket ${S3_BUCKET_NAME} \
                    --key ${S3_KEY} \
                    --query ContentLength \
                    --output text \
                    --region ${AWS_REGION} 2>/dev/null)
        
        if [ ! -z "${S3_SIZE}" ]; then
            log_message "Verificación S3 exitosa. Tamaño en S3: ${S3_SIZE} bytes"
        else
            log_message "ADVERTENCIA: No se pudo verificar el archivo en S3"
        fi
        
        # Limpiar archivo temporal
        cleanup
        
    else
        handle_error "Subida a S3"
    fi
    
    log_message "=== Backup completado exitosamente ==="
    log_message "Archivo S3: s3://${S3_BUCKET_NAME}/${S3_KEY}"
}

# Ejecutar el backup
perform_backup

# Limpiar logs antiguos (mantener solo los últimos 10 archivos)
find /var/log/rds-backup -name "backup_*.log" -type f | sort | head -n -10 | xargs rm -f 2>/dev/null || true

log_message "Proceso de backup finalizado"
EOF

# Hacer ejecutable el script de backup
chmod +x /opt/rds-backup/mysql_backup.sh

# Crear archivo de variables de entorno
cat > /opt/rds-backup/env_vars.sh << EOF
#!/bin/bash
# Variables de entorno para el script de backup
export RDS_ENDPOINT="${RDS_ENDPOINT}"
export RDS_USERNAME="${RDS_USERNAME}"
export RDS_PASSWORD="${RDS_PASSWORD}"
export DATABASE_NAME="${DATABASE_NAME}"
export S3_BUCKET_NAME="${S3_BUCKET_NAME}"
export AWS_REGION="${AWS_REGION}"
export LOG_GROUP="${LOG_GROUP}"

# Configurar PATH para cron
export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin

# Configurar AWS CLI region por defecto
export AWS_DEFAULT_REGION="${AWS_REGION}"
EOF

chmod 644 /opt/rds-backup/env_vars.sh

# Crear wrapper script para cron (maneja mejor el entorno)
cat > /opt/rds-backup/cron_backup.sh << 'EOF'
#!/bin/bash

# Wrapper script para ejecutar desde cron
# Garantiza que el entorno esté configurado correctamente

# Cargar variables de entorno
source /opt/rds-backup/env_vars.sh

# Configurar logging para cron
exec 1>> /var/log/rds-backup/cron.log 2>&1

echo "=== Iniciando backup desde cron a las $(date) ==="

# Verificar que todos los comandos necesarios están disponibles
if ! command -v mysql &> /dev/null; then
    echo "ERROR: MySQL client no está instalado"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI no está disponible"
    exit 1
fi

# Ejecutar el script de backup
/opt/rds-backup/mysql_backup.sh

echo "=== Backup desde cron finalizado a las $(date) ==="
EOF

chmod +x /opt/rds-backup/cron_backup.sh

# Crear script de configuración del cron job
cat > /opt/rds-backup/setup_cron.sh << 'EOF'
#!/bin/bash

# Script para configurar el cron job de backup

echo "Configurando cron jobs para backup de RDS..."

# Eliminar cualquier cron job previo relacionado con backup
crontab -l 2>/dev/null | grep -v "/opt/rds-backup/cron_backup.sh" | crontab -

# Crear nuevo crontab con los jobs de backup
{
    # Mantener cualquier cron job existente que no sea de backup
    crontab -l 2>/dev/null | grep -v "/opt/rds-backup/cron_backup.sh" || true
    
    # Agregar cron job para el viernes 4 de julio a las 6:00 AM (específico)
    # 0 6 4 7 * significa: minuto 0, hora 6, día 4, mes 7 (julio), cualquier día de la semana
    echo "0 6 4 7 * /opt/rds-backup/cron_backup.sh"
    
    # Agregar cron job para todos los viernes a las 6:00 AM (para pruebas y backup regular)
    # 0 6 * * 5 significa: minuto 0, hora 6, cualquier día del mes, cualquier mes, viernes (5)
    echo "0 6 * * 5 /opt/rds-backup/cron_backup.sh"
    
    # Cron job adicional para limpiar logs antiguos (domingo a las 2 AM)
    echo "0 2 * * 0 find /var/log/rds-backup -name '*.log' -mtime +7 -delete"
    
} | crontab -

echo "Cron jobs configurados:"
crontab -l
EOF

chmod +x /opt/rds-backup/setup_cron.sh

# Configurar el servicio crond
systemctl enable crond
systemctl start crond

# Ejecutar la configuración del cron
/opt/rds-backup/setup_cron.sh

# Crear el log group en CloudWatch si no existe
aws logs create-log-group --log-group-name ${LOG_GROUP} --region ${AWS_REGION} 2>/dev/null || true
aws logs create-log-stream --log-group-name ${LOG_GROUP} --log-stream-name $(hostname) --region ${AWS_REGION} 2>/dev/null || true

# Configurar CloudWatch Agent para monitoreo
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW_CONFIG'
{
    "agent": {
        "metrics_collection_interval": 300,
        "run_as_user": "root"
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/rds-backup/*.log",
                        "log_group_name": "/aws/rds-backup/mysql",
                        "log_stream_name": "{hostname}/backup-logs",
                        "timezone": "America/New_York",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/rds-backup/cron.log",
                        "log_group_name": "/aws/rds-backup/mysql",
                        "log_stream_name": "{hostname}/cron-logs",
                        "timezone": "America/New_York"
                    }
                ]
            }
        }
    },
    "metrics": {
        "namespace": "RDS/Backup",
        "metrics_collected": {
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 300,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 300
            }
        }
    }
}
CW_CONFIG

# Iniciar el CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s

# Crear script de verificación del sistema
cat > /opt/rds-backup/verify_setup.sh << 'EOF'
#!/bin/bash

echo "=== Verificación del Sistema de Backup RDS ==="
echo "Fecha: $(date)"
echo ""

# Verificar servicios
echo "1. Verificando servicios..."
systemctl is-active crond && echo "✓ Crond está activo" || echo "✗ Crond no está activo"
systemctl is-active amazon-cloudwatch-agent && echo "✓ CloudWatch Agent está activo" || echo "✗ CloudWatch Agent no está activo"

echo ""

# Verificar archivos y permisos
echo "2. Verificando archivos de backup..."
[ -f /opt/rds-backup/mysql_backup.sh ] && echo "✓ Script de backup existe" || echo "✗ Script de backup no existe"
[ -x /opt/rds-backup/mysql_backup.sh ] && echo "✓ Script de backup es ejecutable" || echo "✗ Script de backup no es ejecutable"
[ -f /opt/rds-backup/env_vars.sh ] && echo "✓ Variables de entorno configuradas" || echo "✗ Variables de entorno no configuradas"

echo ""

# Verificar cron jobs
echo "3. Verificando cron jobs..."
crontab -l | grep -q "/opt/rds-backup/cron_backup.sh" && echo "✓ Cron jobs configurados" || echo "✗ Cron jobs no configurados"

echo ""

# Verificar conectividad
echo "4. Verificando conectividad..."
source /opt/rds-backup/env_vars.sh

# Test MySQL connection
if mysql -h ${RDS_ENDPOINT} -u ${RDS_USERNAME} -p${RDS_PASSWORD} -e "SELECT 1;" 2>/dev/null; then
    echo "✓ Conexión a RDS MySQL exitosa"
else
    echo "✗ No se puede conectar a RDS MySQL"
fi

# Test S3 access
if aws s3 ls s3://${S3_BUCKET_NAME}/ --region ${AWS_REGION} >/dev/null 2>&1; then
    echo "✓ Acceso a S3 exitoso"
else
    echo "✗ No se puede acceder a S3"
fi

echo ""

# Mostrar próximas ejecuciones del cron
echo "5. Próximas ejecuciones programadas:"
echo "Cron jobs actuales:"
crontab -l | grep "/opt/rds-backup/cron_backup.sh"

echo ""
echo "=== Verificación completa ==="
EOF

chmod +x /opt/rds-backup/verify_setup.sh

# Crear script de prueba manual
cat > /opt/rds-backup/test_backup.sh << 'EOF'
#!/bin/bash

echo "=== Ejecutando Prueba de Backup ==="
echo "ADVERTENCIA: Esta es una prueba. Se ejecutará un backup real."
echo ""

read -p "¿Desea continuar? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Ejecutando backup de prueba..."
    /opt/rds-backup/mysql_backup.sh
    echo ""
    echo "Prueba de backup completada. Revise los logs en /var/log/rds-backup/"
else
    echo "Prueba cancelada."
fi
EOF

chmod +x /opt/rds-backup/test_backup.sh

# Crear documentación del sistema
cat > /opt/rds-backup/README.md << 'EOF'
# Sistema de Backup Automático RDS MySQL

## Descripción
Este sistema automatiza el backup de una base de datos MySQL en RDS y almacena los backups en S3.

## Archivos del Sistema

### Scripts Principales
- `/opt/rds-backup/mysql_backup.sh` - Script principal de backup
- `/opt/rds-backup/cron_backup.sh` - Wrapper para ejecución desde cron
- `/opt/rds-backup/env_vars.sh` - Variables de entorno

### Scripts de Utilidad
- `/opt/rds-backup/verify_setup.sh` - Verificar configuración del sistema
- `/opt/rds-backup/test_backup.sh` - Ejecutar backup de prueba manual
- `/opt/rds-backup/setup_cron.sh` - Reconfigurar cron jobs

### Logs
- `/var/log/rds-backup/backup_YYYYMMDD_HHMMSS.log` - Logs de cada backup
- `/var/log/rds-backup/cron.log` - Logs de ejecuciones desde cron

## Programación
- **Viernes 4 de Julio a las 6:00 AM** - Backup específico solicitado
- **Todos los viernes a las 6:00 AM** - Backup semanal regular
- **Domingos a las 2:00 AM** - Limpieza de logs antiguos

## Comandos Útiles

### Verificar el estado del sistema
```bash
sudo /opt/rds-backup/verify_setup.sh
```

### Ejecutar backup manual
```bash
sudo /opt/rds-backup/test_backup.sh
```

### Ver logs de backup
```bash
sudo tail -f /var/log/rds-backup/cron.log
sudo ls -la /var/log/rds-backup/
```

### Ver cron jobs configurados
```bash
sudo crontab -l
```

### Verificar estado de servicios
```bash
sudo systemctl status crond
sudo systemctl status amazon-cloudwatch-agent
```

## Estructura en S3
Los backups se almacenan en: `s3://bucket-name/mysql-backups/YYYY/MM/database_backup_YYYYMMDD_HHMMSS.sql.gz`

## Troubleshooting

### El backup no se ejecuta
1. Verificar que crond esté corriendo: `sudo systemctl status crond`
2. Revisar logs de cron: `sudo tail /var/log/rds-backup/cron.log`
3. Verificar permisos: `sudo ls -la /opt/rds-backup/`

### Error de conexión a RDS
1. Verificar credenciales en `/opt/rds-backup/env_vars.sh`
2. Verificar connectividad de red
3. Verificar que el security group permita conexión MySQL (puerto 3306)

### Error de acceso a S3
1. Verificar que el IAM role tenga permisos correctos
2. Verificar que el bucket existe
3. Verificar configuración de región en AWS CLI
EOF

# Crear estado de inicialización
cat > /opt/rds-backup/init_status.txt << EOF
RDS Backup Instance initialized successfully
Date: $(date)
Hostname: $(hostname)
Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "Unknown")
Region: ${AWS_REGION}
RDS Endpoint: ${RDS_ENDPOINT}
Database: ${DATABASE_NAME}
S3 Bucket: ${S3_BUCKET_NAME}

Configuration completed:
- MySQL client installed
- AWS CLI configured
- Backup scripts created
- Cron jobs scheduled
- CloudWatch agent configured
- Logging configured
EOF

# Ejecutar verificación inicial
echo "Ejecutando verificación inicial del sistema..."
/opt/rds-backup/verify_setup.sh >> /opt/rds-backup/init_status.txt

# Log de finalización
echo "$(date '+%Y-%m-%d %H:%M:%S') - Configuración de instancia RDS Backup completada exitosamente" >> /var/log/cloud-init-output.log

echo "=== Configuración completada ==="
echo "Para verificar el estado del sistema, ejecute: sudo /opt/rds-backup/verify_setup.sh"
echo "Para ejecutar una prueba manual, ejecute: sudo /opt/rds-backup/test_backup.sh"