locals {
  user_data = templatefile("${path.module}/../scripts/install-palworld.sh", {
    data_volume_id     = aws_ebs_volume.palworld_data.id
    data_volume_device = var.data_volume_device_name
    server_name        = var.server_name
    server_description = var.server_description
    server_password    = var.server_password
    admin_password     = var.admin_password
    max_players        = var.max_players
  })
}

# 팰월드 서버 본체 - 상시 접속형 스팟 인스턴스.
#
# instance_market_options를 persistent + interruption_behavior=stop 으로 설정하면,
# 스팟 용량 회수로 중단될 때 AWS가 인스턴스를 "종료"가 아니라 "정지"시키고,
# 나중에 스팟 용량이 다시 확보되면 같은 인스턴스를 자동으로 재기동해준다.
# (이때 EBS 루트/데이터 볼륨, Elastic IP 연결이 그대로 유지된다.)
#
# 접속자가 있는 상태에서 중단이 예고되면 Lambda(lambda.tf)가 개입해서
# 온디맨드 인스턴스로 즉시 대체 기동하고 이 인스턴스는 강제 종료한다.
# 그 경우 아래 aws_instance/aws_eip_association 리소스는 Terraform state 상으로는
# 여전히 "옛 인스턴스"를 가리키게 되므로, 상황이 안정화된 뒤
# `terraform apply -replace="aws_instance.palworld"` 로 재조정이 필요하다.
# (자세한 내용은 docs/ARCHITECTURE.md 참고)
resource "aws_instance" "palworld" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [aws_security_group.palworld.id]
  iam_instance_profile   = aws_iam_instance_profile.palworld.name
  key_name               = var.key_name
  user_data              = local.user_data

  instance_market_options {
    market_type = "spot"

    spot_options {
      max_price                      = var.spot_max_price
      spot_instance_type             = "persistent"
      instance_interruption_behavior = "stop"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.project_name}-server"
  }

  lifecycle {
    # user_data 변경은 이미 떠있는 인스턴스에 적용하지 않는다. AWS는 실행 중인
    # 인스턴스의 user_data를 바꾸려면 정지->수정->재시작을 거치는데, 스팟
    # 인스턴스는 수동으로 정지시키면 spot request가 "disabled" 상태로 빠져서
    # 재시작이 즉시 보장되지 않는다 (실제로 이 문제로 서버가 잠깐 내려간 적
    # 있음). install-palworld.sh를 고쳐도 새 코드는 aws_ssm_parameter.user_data
    # 를 통해 앞으로 Lambda가 새로 띄우는 인스턴스에만 적용되며, 이미 떠있는
    # 이 인스턴스는 그대로 둔다.
    ignore_changes = [user_data]
  }
}

resource "aws_eip_association" "palworld" {
  instance_id   = aws_instance.palworld.id
  allocation_id = aws_eip.palworld.id
}
