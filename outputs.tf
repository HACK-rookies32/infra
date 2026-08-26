output "alb_dns_name" {
  description = "ALB DNS name. Used directly when no domain is configured."
  value       = aws_lb.ext_alb.dns_name
}

# 가비아 관리 페이지 > 네임서버 설정에 입력할 값 4 개.
# 이것이 도메인 연결에서 유일하게 손으로 하는 단계이며, 최초 1 회만 하면 된다.
output "route53_name_servers" {
  description = "Set these 4 name servers at your registrar (Gabia). One-time manual step."
  value       = var.domain_name != "" ? data.aws_route53_zone.main[0].name_servers : []
}

output "service_url" {
  description = "Public URL of the service"
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_lb.ext_alb.dns_name}"
}

# 2. 내부 통신 엔드포인트
output "internal_nlb_dns_name" {
  description = "Internal NLB DNS Name for Web to WAS"
  value       = aws_lb.int_nlb.dns_name
}

output "redis_primary_endpoint" {
  description = "ElastiCache Redis Primary Endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "rds_endpoint" {
  description = "RDS Oracle Endpoint"
  value       = aws_db_instance.oracle.endpoint
}

# 현재 사용 중인 AMI. 시연/발표 전에 이 값을 variables.tf 의
# ubuntu_ami_id 기본값에 박아두면 apply 때 EC2 가 재생성되지 않는다.
output "ubuntu_ami_id" {
  description = "AMI currently in use. Pin this into var.ubuntu_ami_id before a demo."
  value       = local.ubuntu_ami
}

# WAS 는 개별 인스턴스가 아니라 아래 두 엔드포인트로만 접속해야 한다.
output "docdb_cluster_endpoint" {
  description = "DocumentDB Cluster Endpoint (write). Always points to the current writer."
  value       = aws_docdb_cluster.mongo.endpoint
}

output "docdb_reader_endpoint" {
  description = "DocumentDB Reader Endpoint (read-only, load balanced across replicas)"
  value       = aws_docdb_cluster.mongo.reader_endpoint
}