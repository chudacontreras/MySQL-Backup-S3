# Sistema de Backup Automático para RDS MySQL

Sistema de backup automatizado para bases de datos MySQL en Amazon RDS utilizando CloudFormation, EC2 y S3.

## Descripción

Esta solución implementa un sistema completo de backup automático que:
- Ejecuta backups programados de bases de datos MySQL en RDS
- Almacena los backups en S3 con cifrado y versionado
- Implementa políticas de retención y transición a almacenamiento económico
- Monitorea las operaciones mediante CloudWatch Logs
- Proporciona scripts de restauración

## Arquitectura

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   RDS MySQL │◄─────│ EC2 Instance │─────►│  S3 Bucket  │
│   Database  │      │  (t3.micro)  │      │   Backups   │
└─────────────┘      └──────────────┘      └─────────────┘
                            │
                            ▼
                     ┌──────────────┐
                     │  CloudWatch  │
                     │     Logs     │
                     └──────────────┘
```

## Componentes

### Plantillas CloudFormation

1. **s3-bucket.yaml** - Bucket S3 para almacenar backups
   - Versionado habilitado
   - Cifrado AES256
   - Políticas de ciclo de vida (30 días retención)
   - Transición a IA después de 7 días
   - Transición a Glacier después de 30 días

2. **iam-roles-policy.yaml** - Roles y políticas IAM
   - Role para instancia EC2
   - Permisos para acceso a RDS, S3 y CloudWatch
   - Instance Profile para asociar a EC2

3. **ec2-instance.yaml** - Instancia EC2 para ejecutar backups
   - Amazon Linux 2
   - User data con configuración automática
   - Security Group configurado
   - Cron jobs programados

### Scripts

- **user-data-script-v1.sh** - Script de inicialización completo para EC2
- **user-data-script-v2.sh** - Versión alternativa del script de inicialización
- **parameter.json** - Parámetros de ejemplo para los stacks

### Subdirectorio rds-backup-project/

Contiene versiones alternativas y componentes adicionales:
- Plantillas CloudFormation modulares
- Scripts de cron job
- Script de restauración
- Configuración de EFS (opcional)

## Despliegue

### Prerrequisitos

- AWS CLI configurado
- Permisos para crear recursos CloudFormation, EC2, S3, IAM
- VPC y subnet existentes
- Instancia RDS MySQL accesible

### Orden de Despliegue

1. **Crear el bucket S3:**
```bash
aws cloudformation create-stack \
  --stack-name s3-rds-backup-bucket \
  --template-body file://s3-bucket.yaml \
  --parameters ParameterKey=BucketName,ParameterValue=aelis4-rds-backup-bucket-prod \
               ParameterKey=RetentionDays,ParameterValue=30
```

2. **Crear roles IAM:**
```bash
aws cloudformation create-stack \
  --stack-name iam-rds-backup-roles \
  --template-body file://iam-roles-policy.yaml \
  --parameters ParameterKey=S3BucketName,ParameterValue=aelis4-rds-backup-bucket-prod \
  --capabilities CAPABILITY_NAMED_IAM
```

3. **Actualizar parameter.json con tus valores:**
```json
{
  "ParameterKey": "RDSEndpoint",
  "ParameterValue": "tu-rds-endpoint.cluster-xxx.us-east-1.rds.amazonaws.com"
},
{
  "ParameterKey": "RDSPassword",
  "ParameterValue": "tu-password-seguro"
}
```

4. **Crear instancia EC2:**
```bash
aws cloudformation create-stack \
  --stack-name ec2-rds-backup-instance \
  --template-body file://ec2-instance.yaml \
  --parameters file://parameter.json
```

### Verificación

Después del despliegue, conéctate a la instancia EC2 y ejecuta:

```bash
sudo /opt/rds-backup/verify_setup.sh
```

## Programación de Backups

Los backups están programados para ejecutarse:
- **Viernes 4 de julio a las 6:00 AM** (específico)
- **Todos los viernes a las 6:00 AM** (semanal)
- **Limpieza de logs antiguos:** Domingos a las 2:00 AM

Para modificar la programación, edita el cron:
```bash
sudo crontab -e
```

## Operaciones

### Ejecutar Backup Manual

```bash
sudo /opt/rds-backup/test_backup.sh
```

### Ver Logs

```bash
# Logs de backup
sudo tail -f /var/log/rds-backup/cron.log

# Listar todos los logs
sudo ls -la /var/log/rds-backup/

# Ver log específico
sudo cat /var/log/rds-backup/backup_YYYYMMDD_HHMMSS.log
```

### Verificar Backups en S3

```bash
aws s3 ls s3://tu-bucket-name/mysql-backups/ --recursive --human-readable
```

### Restaurar un Backup

```bash
# Descargar backup desde S3
aws s3 cp s3://tu-bucket-name/mysql-backups/YYYY/MM/backup.sql.gz /tmp/

# Descomprimir
gunzip /tmp/backup.sql.gz

# Restaurar en RDS
mysql -h tu-rds-endpoint -u admin -p database_name < /tmp/backup.sql
```

## Estructura de Archivos en la Instancia EC2

```
/opt/rds-backup/
├── mysql_backup.sh          # Script principal de backup
├── cron_backup.sh           # Wrapper para cron
├── env_vars.sh              # Variables de entorno
├── setup_cron.sh            # Configuración de cron jobs
├── verify_setup.sh          # Verificación del sistema
├── test_backup.sh           # Prueba manual de backup
├── README.md                # Documentación local
└── init_status.txt          # Estado de inicialización

/var/log/rds-backup/
├── backup_*.log             # Logs individuales de cada backup
└── cron.log                 # Logs de ejecuciones desde cron
```

## Estructura en S3

```
s3://bucket-name/
└── mysql-backups/
    └── YYYY/
        └── MM/
            └── database_backup_YYYYMMDD_HHMMSS.sql.gz
```

## Monitoreo

### CloudWatch Logs

Los logs se envían automáticamente a CloudWatch:
- Log Group: `/aws/rds-backup/mysql`
- Log Streams: 
  - `{hostname}/backup-logs` - Logs de backups
  - `{hostname}/cron-logs` - Logs de cron

### Métricas CloudWatch

El CloudWatch Agent recopila:
- Uso de disco
- Uso de memoria
- Namespace: `RDS/Backup`

## Troubleshooting

### El backup no se ejecuta

1. Verificar servicio cron:
```bash
sudo systemctl status crond
```

2. Revisar logs:
```bash
sudo tail -100 /var/log/rds-backup/cron.log
```

3. Verificar cron jobs:
```bash
sudo crontab -l
```

### Error de conexión a RDS

1. Verificar credenciales:
```bash
sudo cat /opt/rds-backup/env_vars.sh
```

2. Probar conexión manual:
```bash
mysql -h tu-rds-endpoint -u admin -p -e "SELECT 1;"
```

3. Verificar Security Group de RDS permite conexión desde EC2

### Error de acceso a S3

1. Verificar IAM role:
```bash
aws sts get-caller-identity
```

2. Probar acceso a S3:
```bash
aws s3 ls s3://tu-bucket-name/
```

3. Verificar permisos del IAM role en la consola AWS

### Backup incompleto o corrupto

1. Verificar espacio en disco:
```bash
df -h
```

2. Verificar tamaño del backup:
```bash
aws s3 ls s3://tu-bucket-name/mysql-backups/ --recursive --human-readable
```

3. Descargar y verificar integridad:
```bash
aws s3 cp s3://bucket/path/backup.sql.gz /tmp/
gunzip -t /tmp/backup.sql.gz
```

## Seguridad

### Medidas Implementadas

- Las credenciales de RDS se almacenan en variables de entorno en la instancia
- El bucket S3 tiene cifrado habilitado (AES256)
- Acceso público bloqueado en el bucket S3
- IAM roles con permisos mínimos necesarios
- Security Group restringe acceso a la instancia EC2

### Recomendaciones de Seguridad

#### Antes de Usar en Producción

1. **Reemplazar todos los valores de ejemplo** con los valores reales de tu infraestructura
2. **Nunca commitear credenciales** en el repositorio
3. **Usar AWS Secrets Manager o Parameter Store** para almacenar:
   - Contraseñas de bases de datos
   - Endpoints de RDS
   - Nombres de buckets S3
4. **Implementar rotación de credenciales** periódicamente
5. **Usar variables de entorno** o archivos de configuración externos
6. **Habilitar MFA** para acceso a recursos críticos
7. **Revisar Security Groups** para permitir solo el tráfico necesario
8. **Implementar logging y auditoría** de todos los accesos
9. **Configurar SNS** para notificaciones de fallos
10. **Implementar backup cross-region** para disaster recovery

#### Gestión de Secretos con AWS Secrets Manager

```bash
# Crear secreto para credenciales de RDS
aws secretsmanager create-secret \
  --name rds/backup/credentials \
  --secret-string '{
    "username":"admin",
    "password":"tu-password-seguro",
    "endpoint":"tu-rds-endpoint.rds.amazonaws.com",
    "database":"tu-database"
  }'

# Recuperar secreto en el script
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id rds/backup/credentials \
  --query SecretString \
  --output text)

DB_USER=$(echo $SECRET | jq -r '.username')
DB_PASS=$(echo $SECRET | jq -r '.password')
```

#### Gestión de Parámetros con Parameter Store

```bash
# Almacenar parámetros de forma segura
aws ssm put-parameter \
  --name /rds/backup/endpoint \
  --value "tu-rds-endpoint.rds.amazonaws.com" \
  --type SecureString

aws ssm put-parameter \
  --name /rds/backup/password \
  --value "tu-password-seguro" \
  --type SecureString

# Recuperar parámetros en el script
DB_ENDPOINT=$(aws ssm get-parameter \
  --name /rds/backup/endpoint \
  --with-decryption \
  --query Parameter.Value \
  --output text)

DB_PASSWORD=$(aws ssm get-parameter \
  --name /rds/backup/password \
  --with-decryption \
  --query Parameter.Value \
  --output text)
```

#### Verificación de Seguridad

Para verificar que no quedan datos sensibles en el código:

```bash
# Buscar posibles VPC IDs reales
grep -r "vpc-0[a-f0-9]\{17\}" .

# Buscar posibles Subnet IDs reales
grep -r "subnet-0[a-f0-9]\{17\}" .

# Buscar posibles AMI IDs reales
grep -r "ami-0[a-f0-9]\{17\}" .

# Buscar posibles Access Keys (formato AKIA...)
grep -r "AKIA[0-9A-Z]\{16\}" .

# Buscar posibles Secret Keys (base64)
grep -r "[A-Za-z0-9/+=]\{40\}" .
```

#### Hardening de la Instancia EC2

1. **Deshabilitar acceso SSH público** - Usar AWS Systems Manager Session Manager
2. **Implementar fail2ban** para protección contra ataques de fuerza bruta
3. **Configurar actualizaciones automáticas de seguridad**
4. **Habilitar CloudWatch Logs para auditoría**
5. **Usar IMDSv2** para metadata de instancia
6. **Implementar AWS Config** para compliance continuo

#### Protección del Bucket S3

1. **Habilitar MFA Delete** para prevenir eliminación accidental
2. **Configurar Object Lock** para backups críticos
3. **Implementar bucket policies** restrictivas
4. **Habilitar S3 Access Logging**
5. **Configurar S3 Event Notifications** para monitoreo
6. **Usar S3 Bucket Keys** para reducir costos de KMS

## Costos Estimados

Para una base de datos de tamaño medio con backups semanales:

- **EC2 t3.micro:** ~$7.50/mes (si está corriendo 24/7)
- **S3 Standard-IA:** ~$0.0125/GB/mes
- **S3 Glacier:** ~$0.004/GB/mes
- **CloudWatch Logs:** ~$0.50/GB ingerido
- **Transferencia de datos:** Variable según tamaño de backups

**Optimización:** Considera detener la instancia EC2 cuando no esté en uso y arrancarla con Lambda antes del backup programado.

## Mantenimiento

### Tareas Regulares

- Verificar que los backups se ejecutan correctamente (semanal)
- Revisar logs de CloudWatch (mensual)
- Probar restauración de backups (trimestral)
- Actualizar paquetes del sistema (mensual)
- Revisar costos de S3 y optimizar retención (mensual)

### Actualizaciones

Para actualizar los scripts sin recrear la instancia:

```bash
# Conectarse a la instancia
ssh ec2-user@instance-ip

# Editar el script
sudo nano /opt/rds-backup/mysql_backup.sh

# Probar cambios
sudo /opt/rds-backup/test_backup.sh
```

## Soporte

Para problemas o preguntas:
1. Revisar logs en `/var/log/rds-backup/`
2. Ejecutar script de verificación: `sudo /opt/rds-backup/verify_setup.sh`
3. Consultar CloudWatch Logs en la consola AWS
4. Revisar eventos de CloudFormation para errores de despliegue

## Licencia

Uso interno - Aelis4 Project
