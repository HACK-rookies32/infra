# ==========================================
# 2. Security Groups
# ==========================================

resource "aws_security_group" "ext_alb_sg" {
  name   = "saferookids-ext-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 443 은 도메인이 없을 때도 열어둔다. 리스너가 없으면 어차피 연결이 안 되고,
  # 도메인 확보 시 SG 수정을 잊어 접속이 안 되는 상황을 막기 위함.
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "web_sg" {
  name   = "saferookids-web-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "was_sg" {
  name   = "saferookids-was-sg"
  vpc_id = aws_vpc.main.id

  # ⚠️ 이 CIDR 은 network.tf 의 web_private 서브넷과 손으로 맞춰 둔 값이다.
  #
  #   var.vpc_cidr 이나 network.tf 의 서브넷 대역을 바꾸면 여기도 함께 고쳐야 한다.
  #   안 고치면 apply 는 성공하고 EC2 도 running 인데 WEB -> WAS 통신만 전부
  #   막힌다. 로그도 안 남고 헬스체크만 조용히 실패해서 원인을 찾기 어렵다.
  #
  #   왜 aws_subnet.web_private_2a.cidr_block 을 참조하지 않는가:
  #   참조 자체는 가능하지만, 그렇게 고치려면 network.tf 의 서브넷 8 개도
  #   cidrsubnet() 파생으로 함께 바꾸는 게 일관적이다. 그러면 서브넷이
  #   재생성되면서 EC2 / RDS / DocumentDB / Redis 가 전부 갈린다.
  #   지금 프로젝트에서 vpc_cidr 을 바꿀 일이 없으므로 그 비용을 지지 않기로 했다.
  #
  #   출처가 둘이라는 점도 알아 둘 것:
  #     - WEB EC2 의 요청  (NLB 가 instance 타깃에 원본 IP 를 보존해 전달)
  #     - NLB 자체의 헬스체크 (NLB ENI 가 같은 서브넷에 있음)
  #   둘 다 web_private 대역이라 이 한 줄로 함께 커버된다.
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["192.168.10.0/24", "192.168.11.0/24"] # network.tf 의 web_private_2a / 2c
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "redis_sg" {
  name   = "saferookids-redis-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.was_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "docdb_sg" {
  name   = "saferookids-docdb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.was_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_sg" {
  name   = "saferookids-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 1521
    to_port         = 1521
    protocol        = "tcp"
    security_groups = [aws_security_group.was_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
