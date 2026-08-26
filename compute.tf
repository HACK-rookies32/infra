# ==========================================
# 6. Load Balancers & EC2
# ==========================================

# AMI (Ubuntu 22.04 LTS)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name = "name"
    # 22.04(Jammy) 는 hvm-ssd 경로. hvm-ssd-gp3 는 24.04(Noble) 부터 사용됨.
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ------------------------------------------------------------------
# user_data 템플릿
# WEB : Nginx 로 Vite 빌드 결과물(dist) 서빙 + /api 를 내부 NLB 로 프록시
# WAS : JDK17 + jar 를 systemd 서비스로 기동
# 두 산출물 모두 S3 의 artifacts/ 접두사에서 받아온다.
# ------------------------------------------------------------------
locals {
  # var.ubuntu_ami_id 가 비어 있을 때만 최신 이미지를 조회한다.
  # 값을 넣으면 그것으로 고정되어 apply 때 인스턴스가 갈리지 않는다.
  ubuntu_ami = var.ubuntu_ami_id != "" ? var.ubuntu_ami_id : data.aws_ami.ubuntu.id

  # IMDSv2 강제 설정. EC2 4 대가 모두 같은 값을 쓰므로 여기서 한 번만 정의한다.
  #
  # 기본값(optional)이면 IMDSv1 이 살아 있어, 토큰 없이 단순 GET 한 번으로
  # 인스턴스 IAM 역할의 임시 자격증명을 읽을 수 있다. 즉 앱에 SSRF 취약점이
  # 하나만 있어도 S3 와 SSM 파라미터 권한이 그대로 유출된다.
  # 비밀번호를 user_data 에서 SSM 으로 뺀 것과 같은 맥락의 조치다.
  #
  # hop_limit = 1 : awscli 가 호스트에서 직접 실행되므로 1 홉이면 충분하다.
  #                 컨테이너 안에서 IMDS 를 호출하게 되면 2 로 올려야 한다.
  imds_v2 = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # 루트 볼륨 설정. imds_v2 와 마찬가지로 EC2 4 대가 같은 값을 쓰므로 여기서 정의한다.
  #
  # encrypted = true : RDS(storage_encrypted) / DocumentDB / S3(SSE) 에 이미 적용한
  #   저장 암호화 기준을 EC2 에도 맞춘 것이다. WAS 의 /opt/app/app.env 에는 DB 비밀번호와
  #   JWT 서명 키가 들어 있고, 그게 얹혀 있는 디스크다.
  #
  #   kms_key_id 를 지정하지 않으면 AWS 관리형 키(aws/ebs)를 쓴다 → 키 비용 없음.
  #   t3 는 Nitro 기반이라 암복호화가 하드웨어로 오프로드되어 성능 차이는 없다.
  #
  #   방어 범위를 오해하지 말 것: 인스턴스 안에서 파일을 읽는 것은 그대로 가능하다.
  #   이 설정이 막는 것은 스냅샷/AMI 가 계정 밖으로 나가는 경로다.
  #   (aws/ebs 키로 암호화된 스냅샷은 타 계정 공유·퍼블릭 공유가 API 레벨에서 불가)
  #
  #   ⚠️ EBS 암호화는 볼륨 "생성 시점" 에만 결정된다. 기존 볼륨을 암호화로 전환하는
  #   API 가 존재하지 않으므로, 이 값을 바꾸면 EC2 4 대가 전부 재생성된다.
  #   database.tf 의 storage_encrypted 주석과 정확히 같은 제약이다.
  root_volume = {
    size      = 30
    type      = "gp3"
    encrypted = true
  }

  # EC2 는 티어 안에서 AZ(서브넷)만 다르고 나머지 설정이 전부 같다.
  # 여기에 AZ 를 나열해 두고 아래 aws_instance 가 for_each 로 펼친다.
  # AZ 를 늘리거나 줄일 때 이 맵만 고치면 인스턴스와 타깃그룹 등록이 함께 따라온다.
  web_subnets = {
    "1" = aws_subnet.web_private_2a.id
    "2" = aws_subnet.web_private_2c.id
  }

  was_subnets = {
    "1" = aws_subnet.was_private_2a.id
    "2" = aws_subnet.was_private_2c.id
  }

  # WEB 은 S3 에서 dist 를 받지 않는다. Docker Hub 이미지를 받아 컨테이너로 뜨고,
  # 이후 갱신은 Watchtower 가 처리한다 (templates/web_user_data.sh.tftpl 참고).
  web_user_data = templatefile("${path.module}/templates/web_user_data.sh.tftpl", {
    region                   = var.aws_region
    nlb_dns                  = aws_lb.int_nlb.dns_name
    dockerhub_image          = var.dockerhub_image
    dockerhub_username       = var.dockerhub_username
    dockerhub_token_param    = aws_ssm_parameter.dockerhub_token.name
    watchtower_poll_interval = var.watchtower_poll_interval
  })

  was_user_data = templatefile("${path.module}/templates/was_user_data.sh.tftpl", {
    bucket               = aws_s3_bucket.media.id
    region               = var.aws_region
    oracle_endpoint      = aws_db_instance.oracle.endpoint
    oracle_db_name       = var.oracle_db_name
    docdb_endpoint       = aws_docdb_cluster.mongo.endpoint
    redis_endpoint       = aws_elasticache_replication_group.redis.primary_endpoint_address
    db_username          = var.db_username
    docdb_username       = var.docdb_username
    db_password_param    = aws_ssm_parameter.db_password.name
    docdb_password_param = aws_ssm_parameter.docdb_password.name
    jwt_secret_param     = aws_ssm_parameter.jwt_secret.name
  })
}

# WEB EC2 (2a, 2c) — locals.web_subnets 의 키마다 한 대씩 생성된다.
resource "aws_instance" "web" {
  for_each = local.web_subnets

  ami                    = local.ubuntu_ami
  instance_type          = "t3.small"
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data                   = local.web_user_data
  user_data_replace_on_change = true

  # IMDSv2 강제 (locals.imds_v2 주석 참고)
  metadata_options {
    http_endpoint               = local.imds_v2.http_endpoint
    http_tokens                 = local.imds_v2.http_tokens
    http_put_response_hop_limit = local.imds_v2.http_put_response_hop_limit
  }

  # 루트 볼륨 암호화 (locals.root_volume 주석 참고)
  root_block_device {
    volume_size = local.root_volume.size
    volume_type = local.root_volume.type
    encrypted   = local.root_volume.encrypted
  }
  tags = { Name = "kidhackapp-web-${each.key}" }
}

# External ALB
resource "aws_lb" "ext_alb" {
  name               = "kidhackapp-ext-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ext_alb_sg.id]
  subnets            = [aws_subnet.public_2a.id, aws_subnet.public_2c.id]

  # 채팅(STOMP/SockJS) WebSocket 이 경로상 가장 앞단에서 끊기지 않게 맞춘다.
  # 기본값은 60 초라, 뒤쪽 Nginx proxy_read_timeout(300s) 과 NLB(350s 고정)가
  # 아무리 길어도 유휴 60 초에 ALB 가 먼저 연결을 닫아 버린다.
  # 세 구간 중 가장 짧은 값이 실제 타임아웃이 된다.
  idle_timeout = 300
}

resource "aws_lb_target_group" "web_tg" {
  name     = "kidhackapp-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # 헬스체크는 SPA 폴백을 타지 않는 전용 경로를 쓴다.
  # "/" 로 두면 index.html 전체를 반환해 불필요하게 무겁고, dist 가 깨져도
  # try_files 폴백 때문에 200 이 나올 수 있어 신호가 흐려진다.
  # 이 경로는 이미지의 nginx 설정(web/nginx/default.conf.template)에 정의되어 있다.
  health_check {
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "web" {
  for_each = aws_instance.web

  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = each.value.id
  port             = 80
}

# ------------------------------------------------------------------
# ALB 리스너 (var.domain_name 유무로 자동 분기 — dns.tf 참고)
#
#   domain_name = ""     -> 80 에서 그대로 forward (HTTP 전용)
#   domain_name = "..."  -> 80 은 443 으로 301, 443 에서 forward (HTTPS)
#
# 리스너를 두 벌 정의하고 count 로 하나만 살리는 이유는, ALB 가 포트당
# 리스너를 하나만 가질 수 있기 때문이다. 이 구조라서 "80 으로 만들었다가
# 나중에 443 으로 수동 변경" 하는 단계가 사라진다.
# ------------------------------------------------------------------

# 도메인 없을 때: 80 -> 웹 타깃그룹
resource "aws_lb_listener" "http_forward" {
  count             = var.domain_name == "" ? 1 : 0
  load_balancer_arn = aws_lb.ext_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# 도메인 있을 때: 80 -> 443 영구 리다이렉트
resource "aws_lb_listener" "http_redirect" {
  count             = var.domain_name != "" ? 1 : 0
  load_balancer_arn = aws_lb.ext_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# 도메인 있을 때: 443 -> 웹 타깃그룹
# certificate_arn 을 aws_acm_certificate_validation 에서 가져오는 것이 중요하다.
# 인증서 리소스에서 직접 가져오면 "발급 전" 상태에서도 리스너 생성을 시도해
# 실패한다. 검증 리소스를 거치면 Terraform 이 발급 완료를 기다린다.
resource "aws_lb_listener" "https" {
  count             = var.domain_name != "" ? 1 : 0
  load_balancer_arn = aws_lb.ext_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.cert[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# WAS EC2 (2a, 2c) — locals.was_subnets 의 키마다 한 대씩 생성된다.
resource "aws_instance" "was" {
  for_each = local.was_subnets

  ami                    = local.ubuntu_ami
  instance_type          = "t3.medium"
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.was_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data                   = local.was_user_data
  user_data_replace_on_change = true

  # IMDSv2 강제 (locals.imds_v2 주석 참고)
  metadata_options {
    http_endpoint               = local.imds_v2.http_endpoint
    http_tokens                 = local.imds_v2.http_tokens
    http_put_response_hop_limit = local.imds_v2.http_put_response_hop_limit
  }

  # 루트 볼륨 암호화 (locals.root_volume 주석 참고)
  root_block_device {
    volume_size = local.root_volume.size
    volume_type = local.root_volume.type
    encrypted   = local.root_volume.encrypted
  }
  tags = { Name = "kidhackapp-was-${each.key}" }
}

# Internal NLB
resource "aws_lb" "int_nlb" {
  name               = "kidhackapp-int-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [aws_subnet.web_private_2a.id, aws_subnet.web_private_2c.id]

  # NLB 기본값은 false. 활성화해야 WEB 1 트래픽이 다른 AZ 의 WAS 2 로도 분산됨.
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "was_tg" {
  name     = "kidhackapp-was-tg"
  port     = 8080
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  health_check {
    port     = "8080"
    protocol = "TCP"
  }
}

resource "aws_lb_target_group_attachment" "was" {
  for_each = aws_instance.was

  target_group_arn = aws_lb_target_group.was_tg.arn
  target_id        = each.value.id
  port             = 8080
}

resource "aws_lb_listener" "nlb_tcp" {
  load_balancer_arn = aws_lb.int_nlb.arn
  port              = 8080
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.was_tg.arn
  }
}

# ------------------------------------------------------------------
# 주소 이관 (web_1 → web["1"] 등)
#
# for_each 로 접으면서 리소스 주소가 바뀌었다. moved 블록이 없으면 이미
# apply 한 환경에서 Terraform 이 "옛 주소 destroy + 새 주소 create" 로 읽어
# EC2 4 대를 통째로 재생성한다.
#
# state 에 옛 주소가 없으면 아무 일도 하지 않으므로(no-op) 그냥 둬도 무해하다.
# 팀원 전원이 한 번씩 apply 를 돌린 뒤에는 지워도 된다.
# ------------------------------------------------------------------
moved {
  from = aws_instance.web_1
  to   = aws_instance.web["1"]
}

moved {
  from = aws_instance.web_2
  to   = aws_instance.web["2"]
}

moved {
  from = aws_instance.was_1
  to   = aws_instance.was["1"]
}

moved {
  from = aws_instance.was_2
  to   = aws_instance.was["2"]
}

moved {
  from = aws_lb_target_group_attachment.web_1
  to   = aws_lb_target_group_attachment.web["1"]
}

moved {
  from = aws_lb_target_group_attachment.web_2
  to   = aws_lb_target_group_attachment.web["2"]
}

moved {
  from = aws_lb_target_group_attachment.was_1
  to   = aws_lb_target_group_attachment.was["1"]
}

moved {
  from = aws_lb_target_group_attachment.was_2
  to   = aws_lb_target_group_attachment.was["2"]
}
