output "alb_dns_name" {
  description = "ALB DNS name. Used directly when no domain is configured."
  value       = aws_lb.ext_alb.dns_name
}

# 호스팅 존의 NS 4 개.
# Route 53 등록 도메인이라 등록기관에 입력할 일은 없고, 도메인에 설정된 NS 와
# 일치하는지 확인하는 용도다. 불일치하면 도메인이 이 존을 안 보고 있다는 뜻이며,
# ACM DNS 검증이 영원히 pending 으로 남는 원인이 된다.
#   aws route53domains get-domain-detail --region us-east-1 \
#     --domain-name <도메인> --query "Nameservers[].Name"
output "route53_name_servers" {
  description = "Hosted zone NS records. Must match the domain's configured name servers."
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

# ==========================================
# 관측(observability.tf)
# ==========================================
output "cloudtrail_name" {
  description = "CloudTrail trail name"
  value       = aws_cloudtrail.main.name
}

output "cloudtrail_s3_bucket" {
  description = "S3 bucket holding CloudTrail logs (AWSLogs/<account>/ prefix)"
  value       = aws_s3_bucket.cloudtrail.bucket
}

output "vpc_flow_log_group" {
  description = "CloudWatch Logs group for VPC Flow Logs"
  value       = aws_cloudwatch_log_group.vpc_flow.name
}

output "ec2_log_groups" {
  description = "CloudWatch Logs groups for EC2 host/container logs (streams: <tier>-<instance_id>)"
  value       = { for k, g in aws_cloudwatch_log_group.ec2 : k => g.name }
}

output "secure_share_bucket" {
  description = "Private bucket for sharing sensitive info (intentionally NOT attached to ec2-role)"
  value       = aws_s3_bucket.secure_share.bucket
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

# ==========================================
# backend 레포의 GitHub Secret: APPLICATION_PROD_YML
# ==========================================
# 운영 프로파일 yml 을 인프라 값으로 직접 렌더링한다.
#
# 사람이 엔드포인트를 옮겨 적게 두지 않는 이유:
#   - RDS 엔드포인트는 인스턴스를 다시 만들면 바뀐다. 손으로 옮겨 적은 값은
#     그때부터 조용히 낡는다.
#   - S3 버킷 이름은 틀려도 앱이 예외를 던지지 않고 그냥 실패한다.
#   - Redis 는 TLS 라 호스트가 틀리면 SG 문제처럼 보이는 타임아웃만 남는다.
# 셋 다 "apply 는 성공했는데 앱만 이상한" 형태로 드러나서 원인 찾기가 나쁘다.
#
# 등록 (backend 레포에 대한 권한 필요):
#   ( set -o pipefail
#     terraform output -raw backend_prod_yml | tr -d '\r' | base64 -w0 > /tmp/prod.b64 ) \
#     && test -s /tmp/prod.b64 \
#     && gh secret set APPLICATION_PROD_YML --repo HACK-rookies32/backend < /tmp/prod.b64
#   rm -f /tmp/prod.b64
#
# 한 줄 파이프로 이어 붙이지 말 것. state 가 비어 있으면 terraform output 이
# 실패하는데, pipefail 이 없으면 뒤의 base64 가 빈 문자열을 성공으로 넘기고
# gh 가 그 빈 값을 등록하면서 성공 메시지까지 찍는다. 실제로 한 번 당했다.
# test -s 는 그 빈 값이 시크릿까지 가는 것을 막는 마지막 방어선이다.
#
# tr -d '\r' 은 윈도우용이다. 윈도우 terraform 은 줄바꿈을 CRLF 로 내보내서
# 리눅스에서 만든 것과 바이트가 달라진다(앱은 뜨지만 재현이 안 된다).
#
# 확인 (사이즈가 1000 바이트 미만이면 뭔가 잘못된 것이다):
#   terraform output -raw backend_prod_yml | tr -d '\r' | wc -c
#
# ⚠️ 여기에는 비밀번호/서명키가 일부러 들어 있지 않다. 아래 $${...} 는
#    Terraform 이스케이프라 렌더링 결과에는 ${...} 로 남고, WAS 부팅
#    스크립트가 만드는 /opt/app/app.env 가 그 자리를 채운다.
#    비밀을 이미지에 굽지 않는 이유는 DEPLOY.md 2 장 참고.
#
# ⚠️ sensitive = true 라 apply 끝에 값이 찍히지 않는다. 비밀이라서가 아니라
#    (엔드포인트/계정명뿐이다) 화면을 40 줄 채우기 때문이다. -raw 로 꺼낼 것.
output "backend_prod_yml" {
  description = "Renders application-prod.yml for the backend repo secret APPLICATION_PROD_YML"
  sensitive   = true
  value       = <<-YAML
    # 이 파일은 infra 의 `terraform output -raw backend_prod_yml` 이 생성한다.
    # 손으로 고치지 말 것 — 다음 등록 때 덮어써진다.
    spring:
      datasource:
        url: jdbc:oracle:thin:@//${aws_db_instance.oracle.endpoint}/${var.oracle_db_name}
        username: ${var.db_username}
        password: $${SPRING_DATASOURCE_PASSWORD}
        driver-class-name: oracle.jdbc.OracleDriver
      jpa:
        database-platform: org.hibernate.dialect.OracleDialect
        hibernate:
          # 스키마는 아래 Flyway 가 만든다. Hibernate 는 엔티티와 실제 테이블이
          # 맞는지 검사만 한다. 어긋나면 기동을 거부하므로 스키마 변경이
          # 마이그레이션 없이 새어 나가는 것을 여기서 잡는다.
          ddl-auto: validate
        show-sql: false
      # 앱이 뜰 때 db/migration 의 V1, V2... 를 순서대로 적용한다.
      # 이 값이 없으면 application.yml 의 false 가 그대로 남아 스키마가 만들어지지
      # 않고, 위 validate 가 실패해 앱이 뜨지 않는다.
      #
      # 마이그레이션 SQL 은 Oracle 문법이라 운영에서만 켠다. 로컬/CI 는 H2 라
      # Flyway 를 끄고 ddl-auto 로 스키마를 만든다.
      flyway:
        enabled: true
      h2:
        console:
          enabled: false

      # ⚠️ spring.data.mongodb.uri 가 아니라 spring.mongodb.uri 다.
      # Boot 4.0 에서 접속 키가 옮겨졌고 옛 키는 deprecation level=error 라
      # 바인딩되지 않는다. 옛 키를 쓰면 경고 한 줄 없이 무시되고 드라이버
      # 기본값 localhost:27017 로 붙어, DocumentDB 주소를 넣어도 소용이 없다.
      # (환경변수 이름은 app.env 와 맞추려고 SPRING_DATA_MONGODB_URI 로 유지한다.
      #  아래처럼 플레이스홀더로 직접 참조하므로 이름이 달라도 무방하다.)
      mongodb:
        uri: $${SPRING_DATA_MONGODB_URI}

      data:
        redis:
          host: ${aws_elasticache_replication_group.redis.primary_endpoint_address}
          port: 6379
          # 전송 암호화가 켜져 있어 TLS 로만 접속된다. 빠지면 포트가 열려 있어도
          # 실패하고 SG 문제처럼 보인다.
          ssl:
            enabled: true

    # ALB -> Nginx -> NLB -> WAS 로 프록시가 2 단이다. 없으면 절대 URL 과
    # 리다이렉트가 http:// 로 생성되어 무한 리다이렉트가 난다.
    server:
      forward-headers-strategy: framework

    jwt:
      secret: $${JWT_SECRET}
      expiration: 3600000

    # WAS 부팅 스크립트가 SSM 에서 받아 컨테이너에 읽기 전용으로 마운트한다.
    #
    # 클래스패스가 아니라 파일시스템 경로이므로 file: 접두사가 반드시 필요하다.
    # 빠지면 앱이 jar 안에서 키를 찾다가 실패하고, prod 는 기동을 거부한다.
    firebase:
      credentials-path: file:/run/secrets/firebase.json

    app:
      s3:
        bucket: ${aws_s3_bucket.media.id}
        prefix: uploads
        presign-ttl: 5m

      # 이 줄이 없으면 기본값 mock 이 남아 운영에서도 푸시가 로그로만 남는다.
      # 반대로 firebase 로 켠 뒤 SSM 에 키(/kidhackapp/app/firebase-key)가 없으면
      # 컨테이너가 뜨지 않는다 — 조용히 죽는 것보다 낫다고 보고 그렇게 뒀다.
      # → 키를 SSM 에 먼저 넣고, 그다음 APPLICATION_PROD_YML 을 갱신할 것.
      push:
        provider: firebase

      # STOMP 의 SimpleBroker 는 브로커 프로세스가 아니라 각 JVM 힙 안의 구독자
      # 목록이다. WAS 가 2 대라 같은 방의 두 사람이 서로 다른 인스턴스에 붙으면
      # 한쪽은 메시지를 받지 못한다. redis 로 두면 발행을 Redis 채널로 한 번
      # 돌려 모든 인스턴스가 자기 구독자에게 전달한다.
      #
      # local 이면 지금까지의 동작 그대로다 — 깨지지는 않고 절반만 전달된다.
      chat:
        broker: redis

    # 카드번호 저장 필드암호화 키(Base64 32 바이트). secrets.tf 의
    # random_bytes.card_storage_key 가 만들고 state 가 기억한다.
    #
    # 여기는 값을 직접 렌더링하지 않고 $${...} 플레이스홀더만 남긴다. 실제 값은
    # SSM SecureString(/kidhackapp/app/card-storage-key)에 있고, WAS 부팅
    # 스크립트가 받아 /opt/app/app.env 의 CARD_STORAGE_KEY 로 채운다(jwt.secret 과
    # 동일 경로). 예전에는 값을 직접 구웠는데, 그러면 이미지가 롤백용 sha- 태그
    # 안에도 남아 이미지를 pull 할 수 있는 사람이 카드번호를 복호할 수 있었다.
    #
    # ⚠️ user_data 가 바뀌므로 다음 apply 에서 user_data_replace_on_change = true
    #    로 WAS 2 대가 교체된다(무중단 아님 — 배포창 필요).
    #
    # ⚠️ 들여쓰기 4 칸(= spring/server/jwt/app 과 같은 최상위)이어야 한다.
    #    6 칸으로 넣으면 app.kidhack 이 되는데, Spring 은 모르는 키를 조용히
    #    무시하므로 에러 없이 위의 "임시 키" 상태로 되돌아간다.
    kidhack:
      card:
        storage-key: "$${CARD_STORAGE_KEY}"
  YAML
}