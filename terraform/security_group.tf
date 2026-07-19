resource "aws_security_group" "palworld" {
  name        = "${var.project_name}-sg"
  description = "Palworld dedicated server - only game ports allowed inbound"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# 게임 포트 (UDP 8211)
resource "aws_vpc_security_group_ingress_rule" "game_port" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.palworld.id
  description       = "Palworld game port"
  ip_protocol       = "udp"
  from_port         = 8211
  to_port           = 8211
  cidr_ipv4         = each.value
}

# 쿼리 포트 (UDP 27015) - 서버 목록/상태 조회용
resource "aws_vpc_security_group_ingress_rule" "query_port" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.palworld.id
  description       = "Palworld query port"
  ip_protocol       = "udp"
  from_port         = 27015
  to_port           = 27015
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.palworld.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
