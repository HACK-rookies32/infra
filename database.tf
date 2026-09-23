# ==========================================
# 7. Database (RDS Oracle / DocumentDB) & Cache (ElastiCache)
# ==========================================

# RDS Subnet Group
resource "aws_db_subnet_group" "rds" {
  name       = "kidhackapp-rds-subnet-group"
  subnet_ids = [aws_subnet.db_private_2a.id, aws_subnet.db_private_2c.id]
}

# RDS Option Group (Oracle 전송 암호화)
# storage_encrypted 는 저장 암호화만 담당한다. Oracle 의 WAS<->DB 구간 암호화는
# NNE(Native Network Encryption) 옵션으로 별도 활성화해야 한다.
# Oracle JDBC thin 드라이버는 NNE 를 자동 협상하므로 WAS 쪽 설정 변경은 불필요.
resource "aws_db_option_group" "oracle" {
  name                     = "kidhackapp-oracle-options"
  engine_name              = "oracle-se2"
  major_engine_version     = "19"
  option_group_description = "Native Network Encryption for Oracle"

  option {
    option_name = "NATIVE_NETWORK_ENCRYPTION"

    option_settings {
      name  = "SQLNET.ENCRYPTION_SERVER"
      value = "REQUIRED"
    }
    option_settings {
      name  = "SQLNET.CRYPTO_CHECKSUM_SERVER"
      value = "REQUESTED"
    }
  }
}

# RDS Oracle Instance (Multi-AZ: primary 2a / standby 2c)
resource "aws_db_instance" "oracle" {
  identifier = "kidhackapp-oracle-db"
  engine     = "oracle-se2"
  # Oracle 에서 db_name 은 SID 이며, WAS 의 JDBC URL(.../ORCL)과 반드시 일치해야 한다.
  # 미지정 시 AWS 기본값도 ORCL 이지만, 기본값에 의존하면 어긋났을 때
  # ORA-12514 로만 드러나 원인 파악이 어려우므로 명시한다. 8자 이하 제약.
  db_name                = var.oracle_db_name
  engine_version         = "19"
  license_model          = "license-included"
  instance_class         = "db.t3.medium"
  allocated_storage      = 30
  storage_type           = "gp3"
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  option_group_name      = aws_db_option_group.oracle.name
  # Multi-AZ 배포에서는 availability_zone 을 지정할 수 없음 (RDS API 제약).
  # Primary/Standby AZ 는 서브넷 그룹(db_private_2a, db_private_2c)에서 자동 배치됨.
  multi_az = true

  # 저장 암호화. kms_key_id 미지정 시 AWS 관리형 키(aws/rds) 사용 → 키 비용 없음.
  # 생성 시점에만 지정 가능하며, 이미 생성된 인스턴스에는 켤 수 없다.
  storage_encrypted = true

  # 자동 백업. 프로비저닝 스토리지(30GB) 이하의 백업 스토리지는 무과금.
  # backup_window 와 maintenance_window 는 겹치면 안 됨 (UTC 기준).
  backup_retention_period = 7
  backup_window           = "17:00-18:00"         # KST 02:00-03:00
  maintenance_window      = "sun:18:30-sun:19:30" # KST 일 03:30-04:30
  copy_tags_to_snapshot   = true

  # 최종 스냅샷 여부는 var.keep_final_snapshot 로 제어한다 (variables.tf 주석 참고).
  skip_final_snapshot       = !var.keep_final_snapshot
  final_snapshot_identifier = var.keep_final_snapshot ? "kidhackapp-oracle-db-final" : null
}

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "redis" {
  name       = "kidhackapp-redis-subnet-group"
  subnet_ids = [aws_subnet.db_private_2a.id, aws_subnet.db_private_2c.id]
}

# ElastiCache Redis (Multi-AZ Replication Group)
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "kidhackapp-redis-cluster"
  description                = "Multi-AZ Redis for Session Sharing"
  node_type                  = "cache.t3.micro"
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis_sg.id]
  automatic_failover_enabled = true
  multi_az_enabled           = true
  num_cache_clusters         = 2

  # Primary=2a / Replica=2c 로 고정 (미지정 시 AWS 가 임의 배치)
  preferred_cache_cluster_azs = ["ap-northeast-2a", "ap-northeast-2c"]

  # 저장 암호화(AWS 관리형 키) + 전송 암호화(TLS).
  # transit_encryption_enabled = true 이면 클라이언트가 반드시 TLS 로 접속해야 한다.
  # → WAS 의 Redis 설정을 rediss:// (ssl: true) 로 바꿔야 함. 안 바꾸면 접속 실패.
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # 일 단위 스냅샷. destroy 시 최종 스냅샷은 var.keep_final_snapshot=true 일 때만
  # 남긴다(기본 false → 미생성). 정기 스냅샷은 snapshot_retention_limit(5)로 별도 유지.
  # snapshot_window 는 maintenance_window 와 겹치면 안 됨 (UTC 기준).
  snapshot_retention_limit  = 5
  snapshot_window           = "19:00-20:00"         # KST 04:00-05:00
  maintenance_window        = "sun:20:30-sun:21:30" # KST 일 05:30-06:30
  final_snapshot_identifier = var.keep_final_snapshot ? "kidhackapp-redis-final" : null
}

# DocumentDB Subnet Group
resource "aws_docdb_subnet_group" "docdb" {
  name       = "kidhackapp-docdb-subnet-group"
  subnet_ids = [aws_subnet.db_private_2a.id, aws_subnet.db_private_2c.id]
}

# DocumentDB Cluster Parameter Group
# TLS 는 기본값이 enabled 이지만, 전송 암호화를 코드로 명시해 두기 위해 별도 그룹을 만든다.
resource "aws_docdb_cluster_parameter_group" "docdb" {
  name        = "kidhackapp-docdb-params"
  family      = "docdb5.0"
  description = "Enforce TLS in transit for DocumentDB"

  parameter {
    name  = "tls"
    value = "enabled"
  }
}

# DocumentDB Cluster (Primary 2a / Replica 2c)
resource "aws_docdb_cluster" "mongo" {
  cluster_identifier              = "kidhackapp-docdb-cluster"
  engine                          = "docdb"
  engine_version                  = "5.0.0"
  port                            = 27017
  master_username                 = var.docdb_username
  master_password                 = var.docdb_password
  db_subnet_group_name            = aws_docdb_subnet_group.docdb.name
  vpc_security_group_ids          = [aws_security_group.docdb_sg.id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.docdb.name

  # 저장 암호화(AWS 관리형 키). RDS 와 동일하게 생성 시점에만 지정 가능.
  storage_encrypted = true

  # 자동 백업 + destroy 시 최종 스냅샷 (UTC 기준, 두 창은 겹치면 안 됨)
  backup_retention_period      = 7
  preferred_backup_window      = "17:00-18:00"         # KST 02:00-03:00
  preferred_maintenance_window = "sun:19:30-sun:20:30" # KST 일 04:30-05:30

  skip_final_snapshot       = !var.keep_final_snapshot
  final_snapshot_identifier = var.keep_final_snapshot ? "kidhackapp-docdb-final" : null
}

# 인스턴스 2 대를 각 AZ 에 고정 배치. 먼저 뜬 쪽이 Writer, 나머지가 Reader 가 된다.
# WAS 는 개별 인스턴스가 아니라 아래 outputs 의 클러스터/리더 엔드포인트로만 접속할 것.
resource "aws_docdb_cluster_instance" "mongo_2a" {
  identifier         = "kidhackapp-docdb-2a"
  cluster_identifier = aws_docdb_cluster.mongo.id
  instance_class     = "db.t3.medium"
  availability_zone  = "ap-northeast-2a"
}

resource "aws_docdb_cluster_instance" "mongo_2c" {
  identifier         = "kidhackapp-docdb-2c"
  cluster_identifier = aws_docdb_cluster.mongo.id
  instance_class     = "db.t3.medium"
  availability_zone  = "ap-northeast-2c"

  # 2a 가 먼저 생성되어 Writer 가 되도록 순서를 고정
  depends_on = [aws_docdb_cluster_instance.mongo_2a]
}
